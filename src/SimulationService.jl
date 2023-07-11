module SimulationService

import AMQPClient
import DataFrames: DataFrame
import Dates
import DifferentialEquations
import EasyModelAnalysis
import HTTP
import JobSchedulers
import JSON3
import MathML
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem, ODEProblem
import OpenAPI
import Oxygen
import SciMLBase: SciMLBase, solve
import UUIDs
import YAML

export start!, stop!

#-----------------------------------------------------------------------------# notes
# Example request to /operation/{operation}:
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

# pre-rewrite commit: https://github.com/DARPA-ASKEM/simulation-service/tree/8e4dfc515fd6ddf53067fa535e37450daf1cd63c

#-----------------------------------------------------------------------------# __init__
const rabbit_mq_channel = Ref{Any}() # TODO: replace Any with what AMQPClient.channel returns
const server_url = Ref{String}()
const openapi_spec = Ref{Dict{Any,Any}}()  # populated from https://github.com/DARPA-ASKEM/simulation-api-spec

function __init__()
    if Threads.nthreads() == 1
        @warn "SimulationService.jl requires `Threads.nthreads() > 1`.  Use e.g. `julia --threads=auto`."
    end

    # RabbitMQ Channel to reuse
    if SIMSERVICE_RABBITMQ_ENABLED
        auth_params = Dict{String,Any}(
            "MECHANISM" => "AMQPLAIN",
            "LOGIN" => SIMSERVICE_RABBITMQ_LOGIN,
            "PASSWORD" => SIMSERVICE_RABBITMQ_PASSWORD,
        )
        conn = AMQPClient.connection(; virtualhost="/", host="localhost", port=SIMSERVICE_RABBITMQ_PORT, auth_params)
        rabbitmq_channel[] = AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true)
    end

    server_url[] = "http://$SIMSERVICE_HOST:$SIMSERVICE_PORT"

    openapi_spec[] = YAML.load_file(download("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml"))
end

#-----------------------------------------------------------------------------# start!
function start!(; host=SIMSERVICE_HOST, port=SIMSERVICE_PORT, kw...)
    Threads.nthreads() > 1 || error("Server require `Thread.nthreads() > 1`.  Start Julia via `julia --threads=auto`.")
    stop!()  # Stop server if it's already running
    server_url[] = "http://$host:$port"
    JobSchedulers.scheduler_start()
    JobSchedulers.set_scheduler(max_cpu=0.5, max_mem=0.5, update_second=0.05, max_job=5000)
    Oxygen.resetstate()
    Oxygen.@get "/" health
    Oxygen.@post "/{operation_name}" operation
    Oxygen.@get "/jobs/status/{job_id}" job_status
    Oxygen.@get "/jobs/result/{job_id}" job_result
    Oxygen.@post "/jobs/kill/{job_id}" job_kill
    Oxygen.serveparallel(; host, port, async=true, kw...)
end

#-----------------------------------------------------------------------------# stop!
function stop!()
    JobSchedulers.scheduler_stop()
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

# Terrarium Data Service (TDS)
SIMSERVICE_ENABLE_TDS           = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true"
SIMSERVICE_TDS_URL              = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")
SIMSERVICE_TDS_RETRIES          = parse(Int, get(ENV, "SIMSERVICE_TDS_RETRIES", "10"))


#-----------------------------------------------------------------------------# utils
JSON_HEADER = ["Content-Type" => "application/json"]

get_json(url::String)::JSON3.Object = JSON3.read(HTTP.get(url, JSON_HEADER).body)

# TODO: more tests.  This is an important function.
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

#-----------------------------------------------------------------------------# health: "GET /"
health(::HTTP.Request) = (; status="ok", SIMSERVICE_RABBITMQ_ENABLED, SIMSERVICE_RABBITMQ_ROUTE)

function job_status(::HTTP.Request, job_id::String)
    job = JobSchedulers.job_query(job_id)
    return job.state
end

function job_result(::HTTP.Request, job_id::String)
    job = JobSchedulers.job_query(job_id)
    JobSchedulers.result(job)
end

function job_kill(::HTTP.Request, job_id::String)
    try
        job = JobSchedulers.job_query(job_id)
        JobSchedulers.cancel!(job)
        return HTTP.Response(200)
    catch
        return HTTP.Response(500)
    end
end

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




#-----------------------------------------------------------------------------# Operations
### Example of `obj` inside an OperationRequest
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


# An Operation requires:
#  1) an Operation(::OperationRequest) constructor
#  2) a solve(::Operation; callback) method
#
# An Operation's fields should be separate from any request-specific things for ease of testing.
abstract type Operation end


#-----------------------------------------------------------------------------# OperationRequest
# An OperationRequest contains all the information required to run an Operation
# It's created immediately from a client request and we pass it around to keep all info together
mutable struct OperationRequest{T <: Operation}
    obj::JSON3.Object                   # Untouched JSON from request body
    model_config_ids::Vector{UUIDs.UUID}
    amr::Vector{JSON3.Object}           # ASKEM Model Representations associated with model_config_ids
    timespan::Tuple{Float64, Float64}
    df::DataFrame                       # empty if !haskey(obj, :dataset)
    job_id::String                      # auto-generated in constructor
    operation_type::Type{T}
    results::Any                        # results of solve(operation(::OperationRequest))

    function OperationRequest(req::HTTP.Request)
        obj = JSON3.read(req.body)
        model_config_ids = get_model_config_ids(obj)
        amr = map(id -> get_json("$SIMSERVICE_TDS_URL/model_configurations/$id"), model_config_ids)
        timespan = get_timespan(obj)
        df = get_df(obj)
        job_id = "sciml-$(UUIDs.uuid4())"
        operation_name = split(req.url.path, ",")[end]
        operation_dict = Dict(lowercase(string(T)) => T for T in subtypes(Operation))
        operation_type = operation_dict[operation_name]

        new{operation_type}(obj, model_config_ids, amr, timespan, df, job_id, operation_type, nothing)
    end
end

function get_model_config_ids(obj::JSON3.Object)
    if haskey(obj, :model_config_id)
        return [UUID(obj.model_config_id)]
   elseif haskey(obj, :model_config_ids)
        return UUID.(obj.model_config_ids)
   else
       @warn "JSON request expected to have a `model_config_id` or `model_config_ids` key."
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
    data_url = "$SIMSERVICE_TDS_URL/datasets/$dataset_id/download-url?filename=$filename"
    df = CSV.read(download(get_json(data_url).url), DataFrame)
    rename!(df, Dict(obj.dataset.mappings))
    return df
end

#--------------------------------------------------------------------# IntermediateResults callback
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
get_callback(o::OperationRequest) = DiscreteCallback((args...) -> true, IntermediateResults(o.job_id))

#--------------------------------------------------------------------------# Terrarium Data Service
# Retry a function `n` times if error is HTTP 404
default_retry_contion(ex) = ex isa HTTP.Exceptions.StatusError && ex.status == 404

function retry_n(f; n::Int=SIMSERVICE_TDS_RETRIES, sleep_between::Int=1, condition=default_retry_contion)
    res = nothing
    for _ in 1:SIMSERVICE_TDS_UPDATE_RETRIES
        try
            res = f()
            break
        catch ex
            if condition(ex)
                sleep(sleep_between)
                continue
            else
                rethrow(ex)
            end
        end
    end
    return res
end

function update_job_status!(o::OperationRequest; kw...)
    SIMSERVICE_ENABLE_TDS || return @info "update_job_status!: $kw"
    job_id = o.job_id
    url = "$SIMSERVICE_TDS_URL/simulations/$job_id"  # joshday: rename simulations => jobs?
    obj = retry_n(() -> get_json(url))
    # If JobID is not found in the TDS, we will create it
    obj = isnothing(obj) ? Dict() : Dict(obj)

    body = JSON3.write(merge(Dict(obj), Dict(kw)))
    HTTP.put(url, JSON_HEADER; body=body)
end


function upload_results!(o::OperationRequest)
    isnothing(o.results) && error("No results.  Run `solve!(o)` first.")

    if o.results isa DataFrame
        body = CSV.write(o.results)
        filename = "result.csv"
        header = ["Content-Type" => "text/csv"]
    else
        body = JSON3.write(o.results)
        filename = "result.json"
        header = JSON_HEADER
    end

    upload_url = "$SIMSERVICE_TDS_URL/simulations/sciml-$job_id/upload-url?filename=$filename"
    url = get_json(upload_url).url
    if SIMSERVICE_ENABLE_TDS
        HTTP.put(url, header; body=body)
    else
        @info "upload_results!: $body"
    end
end

#-----------------------------------------------------------------------------# solve!
function solve!(o::OperationRequest)
    update_job_status!(o; status="running", start_time=time())
    operation = o.operation_type(o)
    callback = get_callback(o)
    o.results = solve(operation; callback)
    upload_results!(o)
    update_job_status!(o; status="complete", complete_time=time())
    return o.result
end

#-----------------------------------------------------------------------------# POST /operation/{operation}
function operation(req::HTTP.Request, operation_name::String)
    try
        o = OperationRequest(req)
        job = JobSchedulers.Job(@task(solve!(o)); id=o.job_id)
        JobSchedulers.submit!(job)
        body = JSON3.write((; simulation_id = o.job_id))
        return Response(201, ["Content-Type" => "application/json; charset=utf-8"]; body=body)
    catch ex
        return Response(500, ["Content-Type" => "application/json; charset=utf-8"]; body=JSON3.write((; error=string(ex))))
    end
end


#-----------------------------------------------------------------------------# simulate
struct Simulate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
end

Simulate(o::OperationRequest) = Simulate(ode_system_from_amr(only(o.amr)), o.timespan)

function solve(op::Simulate; kw...)
    prob = ODEProblem(op.sys, [], op.timespan, saveat=1)
    sol = solve(prob; progress = true, progress_steps = 1, kw...)
    DataFrame(sol)
end

#-----------------------------------------------------------------------------# calibrate
struct Calibrate <: Operation
    # TODO
end
Calibrate(o::OperationRequest) = error("TODO")
solve(o::Calibrate; callback) = error("TODO")

#-----------------------------------------------------------------------------# ensemble
struct Ensemble <: Operation
    # TODO
end
Ensemble(o::OperationRequest) = error("TODO")
solve(o::Ensemble; callback) = error("TODO")

end # module
