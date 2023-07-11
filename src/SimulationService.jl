module SimulationService

using AMQPClient: AMQPClient
using DataFrames: DataFrame
using Dates: Dates
using EasyConfig: Config
using HTTP: HTTP
using JobSchedulers: JobSchedulers
using JSON3: JSON3
using ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem
using Oxygen: Oxygen
using SciMLBase: SciMLBase
using UUIDs

export start!, stop!

#-----------------------------------------------------------------------------# notes
# Example request to /operation/{op}:
# {
#   "model_config_id": "22739963-0f82-4d6f-aecc-1082712ed299",
#   "timespan": {"start":0, "end":90},
#   "engine": "sciml",
#   "dataset": {
#     "dataset_id": "adfasdf",
#     "mappings": [], #optional column mappings... renames column headers
#     "filename":"asdfa",
#     }
# }

#-----------------------------------------------------------------------------# __init__
const rabbit_mq_channel = Ref{Any}()

function __init__()
    # RabbitMQ Channel
    auth_params = Dict{String,Any}(
        "MECHANISM" => "AMQPLAIN",
        "LOGIN" => SIMSERVICE_RABBITMQ_LOGIN,
        "PASSWORD" => SIMSERVICE_RABBITMQ_PASSWORD,
    )

    conn = AMQPClient.connection(; virtualhost="/", host="localhost", port=SIMSERVICE_RABBITMQ_PORT, auth_params)
    rabbitmq_channel[] = AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true)
end

#-----------------------------------------------------------------------------# start!
function start!(; host=SIMSERVICE_HOST, port=SIMSERVICE_PORT, kw...)
    stop!()
    Threads.nthreads() > 1 || error("Server require `Thread.nthreads() > 1`.  Start Julia via `julia --threads=auto`.")
    Oxygen.resetstate()
    Oxygen.@get "/" health
    Oxygen.@get "/status/{job_id}" req -> status(req, job_id)
    Oxygen.@post "/operation/{operation}" req -> true # TODO
    Oxygen.serveparallel(; host, port, kw...)
end

#-----------------------------------------------------------------------------# stop!
function stop!()
    Oxygen.terminate()
end

#-----------------------------------------------------------------------------# settings
# Server
SIMSERVICE_HOST                 = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
SIMSERVICE_PORT                 = parse(Int, get(ENV, "SIMSERVICE_PORT", "8000"))

# RabbitMQ (host=localhost)
SIMSERVICE_RABBITMQ_ENABLED     = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true"
SIMSERVICE_RABBITMQ_LOGIN       = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
SIMSERVICE_RABBITMQ_PASSWORD    = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
SIMSERVICE_RABBITMQ_ROUTE       = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "terarium")
SIMSERVICE_RABBITMQ_PORT        = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))

# Terrarium Data Service
SIMSERVICE_ENABLE_TDS           = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true"
SIMSERVICE_TDS_URL              = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")


#-----------------------------------------------------------------------------# utils
JSON_HEADER = ["Content-Type" => "application/json"]

get_json(url::String)::JSON3.Object = JSON3.read(HTTP.get(url, JSON_HEADER).body)

#--------------------------------------------------------------------------# Terrarium Data Service
# DataFrame saved as CSV
# Everything else saved as JSON
function tds_upload(x, job_id::String; name::String="result")
    if !SIMSERVICE_ENABLE_TDS
        return @warn "TDS is not enabled.  `x::$(typeof(x))` will not be uploaded.))"
    end
    ext = x isa DataFrame ? "csv" : "json"
    body = x isa DataFrame ? CSV.write(x) : JSON3.write(x)
    upload_url = "$SIMSERVICE_TDS_URL/simulations/sciml-$job_id/upload-url?filename=$name.$ext"
    url = get_json(upload_url)
    HTTP.put(url, JSON_HEADER; body)
    return first(split(url, '?'))
end

function tds_update_job(job_id::String, updated_fields::Dict{Symbol})
    uuid = gen_uuid(job_id)
    response = nothing
    remaining_retries = 10 # TODO(five)??: Set this with environment variable
    while remaining_retries != 0
        remaining_retries -= 1
        sleep(2)
        try
            response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"])
            break
        catch exception
            if isa(exception,HTTP.Exceptions.StatusError) && exception.status == 404
                response = nothing
            else
                throw(exception)
            end
        end
    end
    if isnothing(response)
            throw("Job cannot finish because it does not exist in TDS")
    end
    body = response.body |> Dict ∘ JSON.read ∘ String
    for field in updated_fields
        body[field.first] = field.second
    end
    HTTP.put("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"], body=JSON.write(body))
end

#-----------------------------------------------------------------------------# health: "GET /"
health(::HTTP.Request) = (; status="ok", SIMSERVICE_RABBITMQ_ENABLED, SIMSERVICE_RABBITMQ_ROUTE)

#-----------------------------------------------------------------------------# RabbitMQ
# Content sent to client as JSON3.write(content)
# If !SIMSERVICE_RABBITMQ_ENABLED, then just log the content
function publish_to_rabbitmq(content)
    SIMSERVICE_RABBITMQ_ENABLED || return @info "publish_to_rabbitmq: $(JSON3.write(content)))"
    json = Vector{UInt8}(codeunits(JSON3.write(content)))
    message = AMQPClient.Message(json, content_type="application/json")
    AMQPClient.basic_publish(rabbitmq_channel[], message; exchange="", routing_key=SIMSERVICE_RABBITMQ_ROUTE)
end
publish_to_rabbitmq(; kw...) = publish_to_rabbitmq(Dict(kw...))

#-----------------------------------------------------------------------------# IntermediateResults
# Publish intermediate results to RabbitMQ with at least `every` seconds inbetween callbacks
mutable struct IntermediateResults
    last_callback::Dates.DateTime  # Track the last time the callback was called
    every::Dates.TimePeriod  # Callback frequency e.g. `Dates.Second(5)`
    job_id::String

    function IntermediateResults(job_id::String; every=Dates.Second(5))
        new(typemin(Dates.DateTime), every, job_id)
    end
end

function (o::IntermediateResults)(integrator)
    if o.last_callback + o.every ≤ Dates.now()
        o.last_callback = Dates.now()
        (; iter, t, u, uprev) = integrator
        publish_to_rabbitmq(; iter=iter, time=t, params=u, abserr=norm(u - uprev), job_id=o.jobid,
            retcode=SciMLBase.check_error(integrator))
    end
end

get_callback(job_id::String) = DiscreteCallback((args...) -> true, IntermediateResults(job_id))


#-----------------------------------------------------------------------------# OperationRequest
### Example of `obj` inside an OperationRequest ###
# {
#   "model_config_id": "22739963-0f82-4d6f-aecc-1082712ed299",
#   "timespan": {"start":0, "end":90},
#   "engine": "sciml",
#   "dataset": {
#     "dataset_id": "adfasdf",
#     "mappings": [], #optional column mappings... renames column headers
#     "filename":"asdfa",
#     }
# }

# ASKEM Model Representation: https://github.com/DARPA-ASKEM/Model-Representations/blob/main/petrinet/petrinet_schema.json
struct OperationRequest{Operation}
    obj::JSON3.Object                   # Untouched JSON from request body
    model_config_ids::Vector{UUID}
    amr::Vector{JSON3.Object}           # ASKEM Model Representations
    timespan::Tuple{Float64, Float64}
    df::DataFrame                       # empty if !haskey(obj, :dataset)
    job_id::String

    function OperationRequest(req::HTTP.Request)
        obj = JSON3.read(req.body)
        model_config_ids = get_model_config_ids(obj)
        amr = map(id -> get_json("$SIMSERVICE_TDS_URL/model_configurations/$id"), model_config_ids)
        timespan = get_timespan(obj)
        df = get_df(obj)
        operation = Symbol(split(req.url.path, "/")[end])
        job_id = "sciml-$(UUIDs.uuid4())"

        return new{operation}(obj, model_config_ids, amr, timespan, df, job_id)
    end
end

function get_model_config_ids(obj::JSON3.Object)
    if haskey(obj, :model_config_id)
        return [UUID(obj.model_config_id)]
   elseif haskey(obj, :model_config_ids)
        return UUID.(obj.model_config_ids)
   else
       error("JSON request to have a `model_config_id` or `model_config_ids` key.")
   end
end

function get_timespan(obj::JSON3.Object)
    if haskey(obj, :timespan)
        map(float, (obj.timespan.start, obj.timespan.end))
    else
        @warn "JSON request doesn't contain `timespan`.  Setting to (0.0, 100.0)."
        (0.0, 100.0)
    end
end

function get_df(obj::JSON3.Object)
    !haskey(obj, :dataset) && return DataFrame()
    (; dataset_id, filename) = obj.dataset
    data_url = string(SIMSERVICE_TDS_URL, "/datasets/$dataset_id/download-url?filename=$filename")
    df = CSV.read(download(get_json(data_url).url), DataFrame)
    rename!(df, Dict(obj.dataset.mappings))
    return df
end

#-----------------------------------------------------------------------------# schedule
function Base.schedule(o::OperationRequest{T}) where {T}
    if T ∉ [:simulate, :calibrate, :ensemble]
        return Response(404, ["Content-Type" => "text/plain; charset=utf-8"], body="Operation $T not found.")
    end

    body = JSON3.write((; simulation_id = o.job_id))
    return Response(201, ["Content-Type" => "application/json; charset=utf-8"]; body=body)

    #     publish_hook = settings["RABBITMQ_ENABLED"] ? publish_to_rabbitmq : (_...) -> nothing

    #     args = json(req, Dict{Symbol,Any})
    #     context = Context(
    #         generate_id(),
    #         publish_hook,
    #         Symbol(operation),
    #         args
    #     )
    #     prog = contextualize_prog(context)
    #     sim_run = Job(@task(prog(args)))
    #     sim_run.id = context.job_id
    #     submit!(sim_run)
    #     uuid = "sciml-" * string(UUID(sim_run.id))
    #     Response(
    #         201,
    #         ["Content-Type" => "application/json; charset=utf-8"],
    #         body=JSON.write("simulation_id" => uuid)
    #     )
    # end
end

#-----------------------------------------------------------------------------# simulate
function run(o::OperationRequest{:simulate})
    sys = ode_system_from_amr(only(o.amr))
    callback = get_callback(o.job_id)
    sol = solve(prob; progress = true, progress_steps = 1, callback)
    return DataFrame(sol)
end


function ode_system_from_amr(obj::JSON3.Object)
    model = obj.model
    ode = obj.semantics.ode

    t = only(@variables t)
    D = Differential(t)

    statenames = [Symbol(s.id) for s in model.states]
    statevars  = [only(@variables $s) for s in statenames]
    statefuncs = [only(@variables $s(t)) for s in statenames]

    # get parameter values and state initial values
    paramnames = [Symbol(x.id) for x in ode.parameters]
    paramvars = [only(@parameters $x) for x in paramnames]
    paramvals = [x.value for x in ode.parameters]
    sym_defs = paramvars .=> paramvals
    initial_exprs = [MathML.parse_str(x.expression_mathml) for x in ode.initials]
    initial_vals = map(x -> substitute(x, sym_defs), initial_exprs)

    # build equations from transitions and rate expressions
    rates = Dict(Symbol(x.target) => MathML.parse_str(x.expression_mathml) for x in ode.rates)
    eqs = Dict(s => Num(0) for s in statenames)
    for tr in model.transitions
        ratelaw = rates[Symbol(tr.id)]
        for s in tr.input
            s = Symbol(s)
            eqs[s] = eqs[s] - ratelaw
        end
        for s in tr.output
            s = Symbol(s)
            eqs[s] = eqs[s] + ratelaw
        end
    end

    subst = Dict(statevars .=> statefuncs)
    eqs = [D(statef) ~ substitute(eqs[state], subst) for (state, statef) in (statenames .=> statefuncs)]

    ODESystem(eqs, t, statefuncs, paramvars; defaults = [statefuncs .=> initial_vals; sym_defs], name=Symbol(obj.name))
end


# import AlgebraicPetri: LabelledPetriNet
# import Symbolics
# import Oxygen: serveparallel, resetstate, json, setschema, terminate, @post, @get
# import SwaggerMarkdown: build, @swagger, OpenAPI, validate_spec, openApiToDict, DOCS
# import YAML
# import JSON3 as JSON
# import JobSchedulers: scheduler_start, set_scheduler, scheduler_stop, submit!, job_query, result, generate_id, update_queue!, Job, JobSchedulers

# include("./service/Service.jl")
# import .Service: make_deterministic_run, retrieve_job
# include("./Settings.jl"); import .Settings: settings

# export start!, stop!

# OPENAPI_SPEC = "paths.yaml"

# """
# Print out settings
# """
# function health_check()
#     tds_url = settings["TDS_URL"]
#     mq_route = settings["RABBITMQ_ROUTE"]

#     return "Simulation-service. TDS_URL=$tds_url, RABBITMQ_ROUTE=$mq_route"
# end


# """
# Specify endpoint to function mappings
# """
# function register!()
#     @get "/" health_check
#     @get "/{element}/{uuid}" retrieve_job
#     @post "/{operation}" make_deterministic_run

#     info = Dict("title" => "Simulation Service", "version" => "0.6.0")
#     openAPI = OpenAPI("3.0.0", info)
#     openAPI.paths = YAML.load_file(OPENAPI_SPEC)
#     documentation = build(openAPI)
#     setschema(documentation)
# end

# """
# Load API endpoints and start listening for sim run jobs
# """
# function start!()
#     resetstate()
#     register!()
#     if Threads.nthreads() > 1
#         set_scheduler(
#             max_cpu=0.5,
#             max_mem=0.5,
#             update_second=0.05,
#             max_job=5000,
#         )
#         scheduler_start()
#         serveparallel(host="0.0.0.0", async=true)
#     else
#         throw("The server is not parallelized. You need to start the REPL like `julia --threads 5`")
#     end
#     nothing
# end

# """
# Shutdown server
# """
# function stop!()
#     scheduler_stop()
#     terminate()
# end

end # module
