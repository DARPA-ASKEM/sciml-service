module SimulationService

import AMQPClient
import CSV
import DataFrames: DataFrame
import Dates: Dates, DateTime, now
import DifferentialEquations
import Downloads: download
import Distributions: Uniform
import EasyConfig: EasyConfig, Config
import EasyModelAnalysis
import HTTP
import InteractiveUtils: subtypes
import JobSchedulers
import JSON3
import JSONSchema
import LinearAlgebra: norm
import MathML
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem, ODEProblem, ODESolution, structural_simplify, states, observed
import OpenAPI
import Oxygen
import SciMLBase: SciMLBase, DiscreteCallback, solve
import StructTypes
import SwaggerMarkdown
import SymbolicUtils
import UUIDs
import YAML

export start!, stop!

#-----------------------------------------------------------------------------# __init__
const rabbitmq_channel = Ref{Any}()
const openapi_spec = Ref{Config}()
const simulation_schema = Ref{Config}()
const petrinet_schema = Ref{Config}()
const server_url = Ref{String}()

function __init__()
    if Threads.nthreads() == 1
        @warn "SimulationService.jl expects `Threads.nthreads() > 1`.  Use e.g. `julia --threads=auto`."
    end
    if RABBITMQ_ENABLED
        auth_params = Dict{String,Any}(
            (; MECHANISM = "AMQPLAIN", LOGIN=RABBITMQ_LOGIN, PASSWORD=RABBITMQ_PASSWORD)
        )
        conn = AMQPClient.connection(; virtualhost="/", host="localhost", port=RABBITMQ_PORT, auth_params)
        @info typeof(AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true))
        rabbitmq_channel[] = AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true)
    end
    simulation_api_spec_main = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main"
    openapi_spec[] = Config(YAML.load_file(download("$simulation_api_spec_main/openapi.yaml")))
    simulation_schema[] = get_json("$simulation_api_spec_main/schemas/simulation.json")
    petrinet_schema[] = get_json("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/petrinet_schema.json")
end

#-----------------------------------------------------------------------------# start!
function start!(; host=HOST, port=PORT, kw...)
    @info "starting server on $host:$port.  nthreads=$(Threads.nthreads())"
    ENABLE_TDS || @warn "TDS is disabled.  Some features will not work."
    stop!()  # Stop server if it's already running
    server_url[] = "http://$host:$port"
    JobSchedulers.scheduler_start()
    JobSchedulers.set_scheduler(max_cpu=0.6, max_mem=0.5, update_second=0.05, max_job=5000)
    Oxygen.resetstate()
    Oxygen.@get     "/"                 health
    Oxygen.@get     "/status/{id}"      job_status
    Oxygen.@post    "/{operation_name}" operation
    Oxygen.@post    "/kill/{id}"        job_kill

    # TODO: bring docs/ back
    # Issue? https://github.com/JuliaData/YAML.jl/issues/117
    # api = SwaggerMarkdown.OpenAPI("3.0", Dict(string(k) => v for (k,v) in openapi_spec[]))
    # swagger = SwaggerMarkdown.build(api)
    # Oxygen.mergeschema(swagger)

    if Threads.nthreads() > 1  # true in production
        Oxygen.serveparallel(; host, port, async=true, kw...)
    else
        @warn "Server starting single-threaded."
        Oxygen.serve(; host, port, async=true, kw...)
    end
end

#-----------------------------------------------------------------------------# stop!
function stop!()
    JobSchedulers.scheduler_stop()
    Oxygen.terminate()
end

#-----------------------------------------------------------------------------# settings
# Server
HOST                 = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
PORT                 = parse(Int, get(ENV, "SIMSERVICE_PORT", "8000"))

# Terrarium Data Service (TDS)
ENABLE_TDS           = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true" #
TDS_URL              = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")
TDS_RETRIES          = parse(Int, get(ENV, "SIMSERVICE_TDS_RETRIES", "10"))

# RabbitMQ (Note: assumes running on localhost)
RABBITMQ_ENABLED     = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true" && SIMSERVICE_ENABLE_TDS
RABBITMQ_LOGIN       = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
RABBITMQ_PASSWORD    = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
RABBITMQ_ROUTE       = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "terarium")
RABBITMQ_PORT        = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))

#-----------------------------------------------------------------------------# utils
JSON_HEADER = ["Content-Type" => "application/json"]

# Get Config object from JSON at `url`
get_json(url::String, T=Config) = JSON3.read(HTTP.get(url, JSON_HEADER).body, T)


#-----------------------------------------------------------------------------# amr_get
# Things that extract info from AMR JSON
# joshday: should all of these be moved into OperationRequest?

# Get `ModelingToolkit.ODESystem` from AMR
function amr_get(obj::Config, ::Type{ODESystem})
    model = obj.model
    ode = obj.semantics.ode

    t = only(@variables t)
    D = Differential(t)

    statenames = [Symbol(s.id) for s in model.states]
    statevars  = [only(@variables $s) for s in statenames]
    statefuncs = [only(@variables $s(t)) for s in statenames]
    obsnames   = [Symbol(o.id) for o in ode.observables]
    obsvars    = [only(@variables $o) for o in obsnames]
    obsfuncs   = [only(@variables $o(t)) for o in obsnames]
    allvars    = [statevars; obsvars]
    allfuncs   = [statefuncs; obsfuncs]

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

    subst = merge!(Dict(allvars .=> allfuncs), Dict(paramvars .=> paramvars))
    eqs = [D(statef) ~ substitute(eqs[state], subst) for (state, statef) in (statenames .=> statefuncs)]

    for (o, ofunc) in zip(ode.observables, obsfuncs)
        expr = substitute(MathML.parse_str(o.expression_mathml), subst)
        push!(eqs, ofunc ~ expr)
    end

    structural_simplify(ODESystem(eqs, t, allfuncs, paramvars; defaults = [statefuncs .=> initial_vals; sym_defs], name=Symbol(obj.name)))
end

# priors
function amr_get(amr::Config, sys::ODESystem, ::Val{:priors})
    paramlist = EasyModelAnalysis.ModelingToolkit.parameters(sys)
    namelist = nameof.(paramlist)

    map(amr.semantics.ode.parameters) do p
        @assert p.distribution.type === "StandardUniform1"
        dist = EasyModelAnalysis.Distributions.Uniform(p.distribution.parameters.minimum, p.distribution.parameters.maximum)
        paramlist[findfirst(x->x==Symbol(p.id),namelist)] => dist
    end
end

# data
function amr_get(df::DataFrame, sys::ODESystem, ::Val{:data})

    statelist = states(sys)
    statenames = string.(statelist)
    statenames = map(statenames) do n; n[1:end-3]; end # there's a better way to do this
    tvals = df[:,"timestamp"]

    map(statelist, statenames) do s,n
        s => (tvals,df[:,n])
    end
end

#-----------------------------------------------------------------------------# job endpoints
get_job(id::String) = JobSchedulers.job_query(jobhash(id))

# Translate our `id` to JobScheduler's `id`
jobhash(id::String) = reinterpret(Int, hash(id))

# translate JobScheduler's `state` to client's `status`
# NOTE: client also has a `:failed` status that indicates the job completed, but with junk results
get_job_status(job::JobSchedulers.Job) =
    job.state == JobSchedulers.QUEUING      ? :queued :
    job.state == JobSchedulers.RUNNING      ? :running :
    job.state == JobSchedulers.DONE         ? :complete :
    job.state == JobSchedulers.FAILED       ? :error :
    job.state == JobSchedulers.CANCELLED    ? :cancelled :
    error("Should be unreachable.  Unknown job state: $(job.state)")


const NO_JOB =
    HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"], body="Job does not exist")

# POST /status/{id}
function job_status(::HTTP.Request, id::String)
    job = get_job(id)
    return isnothing(job) ? NO_JOB : (; status = get_job_status(job))
end

# POST /kill/{id}
function job_kill(::HTTP.Request, id::String)
    job = get_job(id)
    if isnothing(job)
        return NO_JOB
    else
        JobSchedulers.cancel!(job)
        return HTTP.Response(200)
    end
end

#-----------------------------------------------------------------------------# health: GET /
health(::HTTP.Request) = (; status="ok", RABBITMQ_ENABLED, RABBITMQ_ROUTE, ENABLE_TDS)

#-----------------------------------------------------------------------------# OperationRequest
Base.@kwdef mutable struct OperationRequest
    obj::Config = Config()                                  # untouched JSON from request sent by HMI
    id::String = "sciml-$(UUIDs.uuid4())"                   # matches DataServiceModel :id
    operation::Symbol = :unknown                            # :simulate, :calibrate, etc.
    model::Union{Nothing, Config} = nothing                 # ASKEM Model Representation (AMR)
    models::Union{Nothing, Vector{Config}} = nothing        # Multiple models (in AMR)
    timespan::Union{Nothing, NTuple{2, Float64}} = nothing  # (start, end)
    df::Union{Nothing, DataFrame} = nothing                 # dataset (calibrate only)
    result::Any = nothing                               # store result of job
end

function OperationRequest(req::HTTP.Request, operation_name::String)
    o = OperationRequest()
    o.obj = JSON3.read(req.body)
    o.operation = Symbol(operation_name)
    for (k,v) in o.obj
        k == :model_config_id ? (o.model = get_model(v)) :
        k == :model_config_ids ? (o.models = get_model.(v)) :
        k == :timespan ? (o.timespan = (Float64(v.start), Float64(v.end))) :
        k == :dataset ? (o.df = get_dataset(v)) :
        k == :model ? (o.model = v) :
        k == :local_model_file ? (o.model = JSON3.read(v, Config)) :  # For testing only
        k == :local_csv_file ? (o.df = CSV.read(v, DataFrame)) :      # For testing only
        @info "Unprocessed key: $k"
    end
    return o
end

function solve(o::OperationRequest)
    callback = get_callback(o)
    op = OPERATIONS_LIST[o.operation](o)
    o.result = solve(op; callback)
end

#-----------------------------------------------------------------------------# DataServiceModel
# https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/schemas/simulation.json
# How a model/simulation is represented in TDS
# you can HTTP.get("$TDS_URL/simulation") and the JSON3.read(body, DataServiceModel)
Base.@kwdef mutable struct DataServiceModel
    # Required
    id::String = "UNINITIALIZED_ID"         # matches with our `id`
    engine::String = "sciml"                # (ignore) TDS supports multiple engine.  We are the `sciml` engine.
    type::String = "uninitialized"          # :calibration, :calibration_simulation, :ensemble, :simulation
    execution_payload::Config = Config()    # untouched JSON from request sent by HMI
    workflow_id::String = "IGNORED"         # (ignore)
    # Optional
    description::String = ""                                # (ignore)
    timestamp::Union{Nothing, DateTime} = nothing             # (ignore?)
    result_files::Union{Nothing, Vector{String}} = nothing  # URLs of result files in S3
    status::Union{Nothing, String} = "queued"                # queued|running|complete|error|cancelled|failed"
    reason::Union{Nothing, String} = nothing                # why simulation failed (returned junk results)
    start_time::Union{Nothing, DateTime} = nothing          # when job started
    completed_time::Union{Nothing, DateTime} = nothing      # when job completed
    user_id::Union{Nothing, Int64} = nothing                # (ignore)
    project_id::Union{Nothing, Int64} = nothing             # (ignore)
end

# For JSON3 read/write
StructTypes.StructType(::Type{DataServiceModel}) = StructTypes.Mutable()

# Initialize a DataServiceModel
operation_to_dsm_type = Dict(
    :simulate => "simulation",
    :calibrate => "calibration_simulation",
    :ensemble => "ensemble"
)

function DataServiceModel(o::OperationRequest)
    m = DataServiceModel()
    m.id = o.id
    m.type = operation_to_dsm_type[o.operation]
    m.execution_payload = o.obj
    return m
end

#-----------------------------------------------------------------------------# TDS interactions
# Each function in this section needs to handle both cases: ENABLE_TDS=true and ENABLE_TDS=false

function DataServiceModel(id::String)
    if !ENABLE_TDS
        @warn "TDS disabled - DataServiceModel with argument $id"
        return DataServiceModel()  # TODO: mock TDS
    end
    check = (_, e) -> e isa HTTP.Exceptions.StatusError && ex.status == 404
    delays = fill(1, TDS_RETRIES)

    try
        res = retry(() -> HTTP.get("$TDS_URL/simulations/$id"); delays, check)()
        return JSON3.read(res.body, DataServiceModel)
    catch
        return error("No simulation found in TDS with id=$id.")
    end
end

function get_model(id::String)
    if !ENABLE_TDS
        @warn "TDS disabled - get_model with argument $id"
        return Config()  # TODO: mock TDS
    end
    get_json("$TDS_URL/model_configurations/$id")
end

function get_dataset(obj::Config)
    if !ENABLE_TDS
        @warn "TDS disabled - get_dataset with argument $obj"
        return DataFrame()  # TODO: mock tds
    end
    tds_url = "$TDS_URL/datasets/$(obj.id)/download-url?filename=$(obj.filename)"
    s3_url = get_json(tds_url).url
    df = CSV.read(download(s3_url), DataFrame)
    return rename!(df, obj.mappings)
end

# published as JSON3.write(content)
function publish_to_rabbitmq(content)
    if !RABBITMQ_ENABLED
        @warn "TDS disabled - publish_to_rabbitmq with argument $content"
        return content
    end
    json = Vector{UInt8}(codeunits(JSON3.write(content)))
    message = AMQPClient.Message(json, content_type="application/json")
    AMQPClient.basic_publish(rabbitmq_channel[], message; exchange="", routing_key=SIMSERVICE_RABBITMQ_ROUTE)
end
publish_to_rabbitmq(; kw...) = publish_to_rabbitmq(Dict(kw...))


# initialize the DataServiceModel in TDS: POST /simulations/{id}
function create(o::OperationRequest)
    m = DataServiceModel(o)
    body = JSON3.write(m)
    if !ENABLE_TDS
         @warn "TDS disabled - create with JSON $body"
         return body
    end
    HTTP.post("$TDS_URL/simulations/", JSON_HEADER; body)
end

# update the DataServiceModel in TDS: PUT /simulations/{id}
# kw args and their types much match field::fieldtype in DataServiceModel
function update(o::OperationRequest; kw...)
    if !ENABLE_TDS
        @warn "TDS disabled - update OperationRequest with id=$(o.id), $kw"
        return kw
    end
    m = DataServiceModel(o.id)
    for (k,v) in kw
        setproperty!(m, k, v)
    end
    HTTP.put("$TDS_URL/simulations/$(o.id)", JSON_HEADER; body=JSON3.write(m))
end

function complete(o::OperationRequest)
    isnothing(o.result) && error("No result.  Run `solve(o::OperationRequest)` first.")

    if o.result isa DataFrame
        # DataFrame uploaded as CSV file
        io = IOBuffer()
        CSV.write(io, o.result)
        body = String(take!(io))
        filename = "result.csv"
        header = ["Content-Type" => "text/csv"]
    else
        # everything else as JSON file
        body = JSON3.write(o.result)
        filename = "result.json"
        header = JSON_HEADER
    end
    if !ENABLE_TDS
        @warn "TDS disabled - complete(id=$(o.id)): summary(body) = $(summary(body))"
        return body
    end

    tds_url = "$TDS_URL/simulations/sciml-$(o.id)/upload-url?filename=$filename)"
    s3_url = get_json(tds_url).url
    HTTP.put(s3_url, header; body=body)
    update(o; status = "complete", completed_time = Dates.now(), result_files = [s3_url])
end



#-----------------------------------------------------------------------------# POST /{operation}
# For debugging:
last_operation = Ref{OperationRequest}()
last_job = Ref{JobSchedulers.Job}()

#----- Flow/pipeline of how this fits into the whole system -----#
# 1) HMI sends us request to run simulation: POST /simulate
# 2) We create simulation in TDS: POST /simulations
# 3) We get model from TDS: GET /model_configurations/$id
# 4) We start job and update simulation in TDS: PUT /simulations/$id
#     a) Intermediate results are published to TDS via RabbitMQ hook
# 5) Job finishes: We get url from TDS where we can store results: GET /simulations/$sim_id/upload-url?filename=result.csv
# 6) We upload results to S3: PUT $url
# 7) We update simulation in TDS(status="complete", complete_time=<datetime>): PUT /simulations/$id
function operation(request::HTTP.Request, operation_name::String)
    @info "operation requested: $operation_name"
    o = OperationRequest(request, operation_name)  # 1, 3
    @info "Creating in TDS (id=$(o.id)))..."
    create(o)  # 2
    job = JobSchedulers.Job(
        @task begin
            # try
                @info "Updating job (id=$(o.id))...)"
                update(o; status = "running", start_time = Dates.now()) # 4
                @info "Solving job (id=$(o.id))..."
                solve(o) # 5
                @info "Completing job (id=$(o.id))...)"
                complete(o)  # 6, 7
            # catch
            #     update(o; status = :error)
            # end
        end
    )
    job.id = jobhash(o.id)
    @info "Submitting job..."
    JobSchedulers.submit!(job)

    last_operation[] = o
    last_job[] = job

    body = JSON3.write((; simulation_id = o.id))
    return HTTP.Response(201, ["Content-Type" => "application/json; charset=utf-8"], body; request)
end

#-----------------------------------------------------------------------------# operations.jl
include("operations.jl")


end # module
