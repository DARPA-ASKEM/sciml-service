module SimulationService

import AMQPClient
import CSV
import DataFrames: DataFrame
import Dates
import DifferentialEquations
import Downloads: download
import EasyConfig: EasyConfig, Config
import EasyModelAnalysis
import HTTP
import InteractiveUtils: subtypes
import JobSchedulers
import JSON3
import JSONSchema
import MathML
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem, ODEProblem, structural_simplify
import OpenAPI
import Oxygen
import SciMLBase: SciMLBase, DiscreteCallback, solve
import StructTypes
import SwaggerMarkdown
import UUIDs
import YAML

export start!, stop!

#-----------------------------------------------------------------------------# notes
# Example request to /{operation}:
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

# OpenAPI spec: https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml

#-----------------------------------------------------------------------------# __init__
const rabbit_mq_channel = Ref{Any}() # TODO: replace Any with what AMQPClient.channel returns
const server_url = Ref{String}()
const openapi_spec = Ref{Config}()  # populated from https://github.com/DARPA-ASKEM/simulation-api-spec

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

    spec = download("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml")
    openapi_spec[] = Config(YAML.load_file(spec))
end

#-----------------------------------------------------------------------------# start!
function start!(; host=SIMSERVICE_HOST, port=SIMSERVICE_PORT, kw...)
    SIMSERVICE_ENABLE_TDS || @warn "TDS is disabled.  Some features will not work."
    stop!()  # Stop server if it's already running
    server_url[] = "http://$host:$port"
    JobSchedulers.scheduler_start()
    JobSchedulers.set_scheduler(max_cpu=0.5, max_mem=0.5, update_second=0.05, max_job=5000)
    Oxygen.resetstate()
    # routes:
    Oxygen.@get     "/"                 health
    Oxygen.@get     "/status/{job_id}"  job_status
    Oxygen.@get     "/result/{job_id}"  job_result
    Oxygen.@post    "/{operation_name}" operation
    Oxygen.@post    "/kill/{job_id}"    job_kill

    # Below commented out because of: https://github.com/JuliaData/YAML.jl/issues/117 ????
    # api = SwaggerMarkdown.OpenAPI("3.0", Dict(string(k) => v for (k,v) in openapi_spec[]))
    # swagger = SwaggerMarkdown.build(api)
    # Oxygen.mergeschema(swagger)

    # server:
    if Threads.nthreads() > 1  # true in production
        Oxygen.serveparallel(; host, port, async=true, kw...)
    else
        @warn "Server starting single-threaded.  This should only be used for testing. Try starting Julia via `julia --threads=auto`."
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
SIMSERVICE_HOST                 = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
SIMSERVICE_PORT                 = parse(Int, get(ENV, "SIMSERVICE_PORT", "8000"))

# Terrarium Data Service (TDS)
SIMSERVICE_ENABLE_TDS           = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true" #
SIMSERVICE_TDS_URL              = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")
SIMSERVICE_TDS_RETRIES          = parse(Int, get(ENV, "SIMSERVICE_TDS_RETRIES", "10"))

# RabbitMQ (Note: assumes running on localhost)
SIMSERVICE_RABBITMQ_ENABLED     = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true" && SIMSERVICE_ENABLE_TDS
SIMSERVICE_RABBITMQ_LOGIN       = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
SIMSERVICE_RABBITMQ_PASSWORD    = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
SIMSERVICE_RABBITMQ_ROUTE       = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "terarium")
SIMSERVICE_RABBITMQ_PORT        = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))

#-----------------------------------------------------------------------------# MockTDS
# If TDS disabled, then we'll log the data that would've been sent to TDS in mock_tds_cache
struct MockTDS
    what::Symbol
    timestamp::Dates.DateTime
    value::Any
    MockTDS(what::Symbol, value) = new(what, Dates.now(), value)
end
const mock_tds_cache = MockTDS[]
mock_tds!(what, value) = push!(mock_tds_cache, MockTDS(what, value))

#-----------------------------------------------------------------------------# utils
JSON_HEADER = ["Content-Type" => "application/json"]

# Get Config object from JSON at `url`
get_json(url::String)::Config = JSON3.read(HTTP.get(url, JSON_HEADER).body, Config)


#-----------------------------------------------------------------------------# ode_system_from_amr
# Get `ModelingToolkit.ODESystem` from AMR
# TODO: more tests.  This is an important function.
function ode_system_from_amr(obj::Config)
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

#-----------------------------------------------------------------------------# job endpoints
get_job(job_id::String) = JobSchedulers.job_query(jobhash(job_id))

# Translate SimulationService's `job_id` to JobScheduler's `id`
jobhash(job_id::String) = reinterpret(Int, hash(job_id))

# translate JobScheduler's `state` to client's `status`
get_job_status(job::JobSchedulers.Job) =
    job.state == JobSchedulers.QUEUING      ? :queued :
    job.state == JobSchedulers.RUNNING      ? :running :
    job.state == JobSchedulers.DONE         ? :complete :
    job.state == JobSchedulers.FAILED       ? :failed :
    job.state == JobSchedulers.CANCELLED    ? :cancelled :
    error("Should be unreachable.  Unknown job state: $(job.state)")


const NO_JOB =
    HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"], body="Job does not exist")

const INCOMPLETE_JOB =
    HTTP.Response(400, ["Content-Type" => "text/plain; charset=utf-8"], body="Job has not completed")

# /status/{job_id}
function job_status(::HTTP.Request, job_id::String)
    job = get_job(job_id)
    return isnothing(job) ? NO_JOB : (; status = get_job_status(job))
end

# /result/{job_id}
function job_result(request::HTTP.Request, job_id::String)
    job = get_job(job_id)
    isnothing(job) && return NO_JOB
    return job.state == :DONE ? JobSchedulers.result(job) : INCOMPLETE_JOB
end

# /kill/{job_id}
function job_kill(request::HTTP.Request, job_id::String)
    job = get_job(job_id)
    if isnothing(job)
        return NO_JOB
    else
        JobSchedulers.cancel!(job)
        return HTTP.Response(200)  # joshday: need JSON response here?
    end
end


#-----------------------------------------------------------------------------# health: GET /
health(::HTTP.Request) = (; status="ok", SIMSERVICE_RABBITMQ_ENABLED, SIMSERVICE_RABBITMQ_ROUTE,
                            SIMSERVICE_ENABLE_TDS)

#-----------------------------------------------------------------------------# RabbitMQ
# Content sent to client as JSON3.write(content)
# If !SIMSERVICE_RABBITMQ_ENABLED, then just log the content
function publish_to_rabbitmq(content)
    SIMSERVICE_RABBITMQ_ENABLED || return mock_tds!(:publish_to_rabbitmq, content)
    json = Vector{UInt8}(codeunits(JSON3.write(content)))
    message = AMQPClient.Message(json, content_type="application/json")
    AMQPClient.basic_publish(rabbitmq_channel[], message; exchange="", routing_key=SIMSERVICE_RABBITMQ_ROUTE)
end
publish_to_rabbitmq(; kw...) = publish_to_rabbitmq(Dict(kw...))

#-----------------------------------------------------------------------------# SimulationRecord
# This is the information that Terrarium knows about our jobs.
Base.@kwdef mutable struct SimulationRecord
    execution_payload::Config               = Config()  # joshday: Is this the POST-ed JSON?
    type::Symbol                            = :unknown
    status::Symbol                          = :unknown
    engine::Symbol                          = :sciml
    workflow_id::Union{Nothing, String}     = nothing
    id::Union{Nothing, String}              = nothing
    result_files::Vector{String}            = []
    reason::Union{Nothing, String}          = nothing
    start_time::Union{Nothing, String}      = nothing
    completed_time::Union{Nothing, String}  = nothing
    user_id::Union{Nothing, Int64}          = nothing
    project_id::Union{Nothing, Int64}       = nothing
end

StructTypes.StructType(::Type{SimulationRecord}) = StructTypes.Mutable()

function get_sim(job_id)
    url = "$SIMSERVICE_TDS_URL/simulations/$job_id"
    JSON3.read(HTTP.get(url, JSON_HEADER).body, SimulationRecord)
end


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
Base.@kwdef mutable struct OperationRequest{T <: Operation}
    obj::Config                                         = Config() # untouched JSON from request
    required::Config                                    = Config() # required keys for endpoint
    optional::Config                                    = Config() # optional keys for endpoint
    model::Union{Config, Vector{Config}}                = Config() # ASKEM Model Representation(s)
    df::Union{Nothing, DataFrame}                       = nothing
    timespan::Union{Nothing, Tuple{Float64, Float64}}   = nothing
    job_id::String                                      = "unknown_job"
    operation_type::Type{T}                             = T
    results::Any                                        = nothing

    # only update through update_record!(::OperaitonRequest; kw...)
    record::SimulationRecord                            = SimulationRecord()
end

# When TDS disabled, assume `model_config_id` is just a filename in `examples/`
function get_model(model_config_id::String)
    if SIMSERVICE_ENABLE_TDS
        return get_json("$SIMSERVICE_TDS_URL/model_configurations/$model_config_id")
    else
        mock_tds!(:get_model, model_config_id)
        path = joinpath(@__DIR__, "..", "examples", model_config_id)
        if isfile(path)
            return JSON3.read(read(path), Config)
        else
            @warn "No local file found at $path"
            Config()
        end
    end
end

function get_dataset(obj::Config)
    if SIMSERVICE_ENABLE_TDS
        tds_url = "$SIMSERVICE_TDS_URL/datasets/$(obj.id)/download-url?filename=$(obj.filename)"
        s3_url = get_json(tds_url).url
        df = CSV.read(download(s3_url), DataFrame)
        rename!(df, obj.mappings)
        return df
    else
        MockTDS(:get_dataset, obj)
        path = joinpath(@__DIR__, "..", "examples", obj.filename)
        return isfile(path) ? CSV.read(path, DataFrame) : error("File not found: $path")
    end
end

function OperationRequest(req::HTTP.Request, route::String)
    # TODO: validate request with JSONSchema.jl
    @info "Creating OperationRequest: POST $route"
    T = Dict(lowercase(string(T.name.name)) => T for T in subtypes(Operation))[route]
    o = OperationRequest{T}()
    obj = JSON3.read(req.body, Config)
    o.obj = obj
    o.job_id = "sciml-$(UUIDs.uuid4())"
    schema = openapi_spec[].paths["/$route"].post.requestBody.content."application/json".schema
    o.required = Config(k => obj[k] for k in schema.required)
    o.optional = Config(k => obj[k] for k in setdiff(schema.properties, schema.required))
    for (k,v) in obj
        if k == :model_config_id
            o.model = get_model(v)
        elseif k == :model_config_ids
            o.model = get_model.(v)
        elseif k == :timespan
            o.timespan = (Float64(v.start), Float64(v.end))
        elseif k == :dataset  # calibrate only
            o.df = get_dataset(v)
        elseif k == :model
            o.model = v
        else
            @info "Unprocessed key: $k"
        end
    end

    # SimulationRecord init
    o.record.execution_payload = obj
    o.record.type = Symbol(lowercase(string(o.operation_type.name.name)))
    o.record.id = o.job_id
    o.record.status = :queued

    return o
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
default_retry_condition(ex) = ex isa HTTP.Exceptions.StatusError && ex.status == 404

function retry_n(f; n::Int=SIMSERVICE_TDS_RETRIES, sleep_between::Int=1, condition=default_retry_condition)
    res = nothing
    for _ in 1:n
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


function update_record!(o::OperationRequest; kw...)
    if SIMSERVICE_ENABLE_TDS
        res = retry_n(() -> get_sim(o.job_id))
        record = isnothing(res) ? o.record : res
        for (k,v) in kw
            setproperty!(record, k, v)
        end
        o.record = record
        url = "$SIMSERVICE_TDS_URL/simulations/$job_id"
        HTTP.put(url, JSON_HEADER; body=JSON3.write(o.record))
    else
        for (k,v) in kw
            setproperty!(o.record, k, v)
        end
        mock_tds!(:update_record!, o.record)
    end
end

function upload_results!(o::OperationRequest)
    isnothing(o.results) && error("No results.  Run `solve!(o)` first.")

    # DataFrame result saved as CSV.  Everything else saved as JSON.
    if o.results isa DataFrame
        io = IOBuffer()
        CSV.write(io, o.results)
        body = String(take!(io))
        filename = "result.csv"
        header = ["Content-Type" => "text/csv"]
    else
        body = JSON3.write(o.results)
        filename = "result.json"
        header = JSON_HEADER
    end

    if !SIMSERVICE_ENABLE_TDS
        return push!(mock_tds_cache, MockTDS(:upload_results!, o.results))
    end

    tds_url = "$SIMSERVICE_TDS_URL/simulations/sciml-$(o.job_id)/upload-url?filename=$filename)"
    s3_url = get_json(tds_url).url
    HTTP.put(s3_url, header; body=body)
end

#-----------------------------------------------------------------------------# solve!
function solve!(o::OperationRequest)
    try
        update_record!(o; status = :running, start_time = time())
        operation = o.operation_type(o)
        callback = get_callback(o)
        o.results = solve(operation; callback)
        upload_results!(o)
        update_record!(o; status = :complete, complete_time = time())
        return o.results_to_upload
    catch ex
        update_record!(o; status = :error, reason=string(ex))
    end
end

#-----------------------------------------------------------------------------# POST /{operation}
# For debugging.  When a job fails, you can check out last_operation[] and last_job[].
last_operation = Ref{OperationRequest}()
last_job = Ref{JobSchedulers.Job}()

# TODO: add try-catch back in?  It's useful for debugging to leave it out.
function operation(req::HTTP.Request, operation_name::String)
    # try
        o = OperationRequest(req, operation_name)
        @info "Scheduling Job: $(o.job_id)"
        job = JobSchedulers.Job(@task(solve!(o)))
        job.id = jobhash(o.job_id)
        JobSchedulers.submit!(job)

        last_operation[] = o    # For debugging
        last_job[] = job        # For debugging

        body = JSON3.write((; simulation_id = o.job_id))
        return HTTP.Response(201, ["Content-Type" => "application/json; charset=utf-8"], body; request=req)
    # catch ex
    #     return HTTP.Response(500, ["Content-Type" => "application/json; charset=utf-8"], JSON3.write((; error=string(ex))))
    # end
end


#-----------------------------------------------------------------------------# simulate
struct Simulate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
end

Simulate(o::OperationRequest) = Simulate(ode_system_from_amr(o.model), o.timespan)

function solve(op::Simulate; kw...)
    # joshday: What does providing `u0 = []` do?  Don't we know what u0 is from AMR?
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
