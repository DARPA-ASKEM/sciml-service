module SimulationService

import AMQPClient
import CSV
import DataFrames: DataFrame, names, rename!
import Dates: Dates, DateTime, now, UTC
import DifferentialEquations
import Downloads: download
import Distributions: Uniform
import EasyModelAnalysis
import HTTP
import InteractiveUtils: subtypes
import JobSchedulers
import JSON3
# import JSONSchema (TODO: validate requests)
import LinearAlgebra: norm
import MathML
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem, ODEProblem, ODESolution, structural_simplify, states, observed
import OpenAPI
import Oxygen
import Pkg
import SciMLBase: SciMLBase, DiscreteCallback, solve
import StructTypes
import SwaggerMarkdown
import SymbolicUtils
import UUIDs
import YAML
import Statistics

export start!, stop!

#-----------------------------------------------------------------------------# __init__
const rabbitmq_channel = Ref{Any}()
const openapi_spec = Ref{Dict}()
const simulation_schema = Ref{JSON3.Object}()
const petrinet_schema = Ref{JSON3.Object}()
const server_url = Ref{String}()

#-----# Environmental Variables:
# Server configuration
const HOST = Ref{String}()
const PORT = Ref{Int}()
# Terrarium Data Service (TDS)
const ENABLE_TDS = Ref{Bool}()
const TDS_URL = Ref{String}()
const TDS_RETRIES = Ref{Int}()
# RabbitMQ (Note: assumes running on localhost)
const RABBITMQ_ENABLED = Ref{Bool}()
const RABBITMQ_LOGIN = Ref{String}()
const RABBITMQ_PASSWORD = Ref{String}()
const RABBITMQ_ROUTE = Ref{String}()
const RABBITMQ_PORT = Ref{Int}()

function __init__()
    if Threads.nthreads() == 1
        @warn "SimulationService.jl expects `Threads.nthreads() > 1`.  Use e.g. `julia --threads=auto`."
    end
    simulation_api_spec_main = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main"
    openapi_spec[] = YAML.load_file(download("$simulation_api_spec_main/openapi.yaml"))
    simulation_schema[] = get_json("$simulation_api_spec_main/schemas/simulation.json")
    petrinet_schema[] = get_json("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/petrinet_schema.json")

    HOST[] = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
    PORT[] = parse(Int, get(ENV, "SIMSERVICE_PORT", "8080"))
    ENABLE_TDS[] = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true" #
    TDS_URL[] = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")
    TDS_RETRIES[] = parse(Int, get(ENV, "SIMSERVICE_TDS_RETRIES", "10"))
    RABBITMQ_ENABLED[] = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true" && SIMSERVICE_ENABLE_TDS
    RABBITMQ_LOGIN[] = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
    RABBITMQ_PASSWORD[] = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
    RABBITMQ_ROUTE[] = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "terarium")
    RABBITMQ_PORT[] = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))

    if RABBITMQ_ENABLED[]
        auth_params = Dict{String,Any}(
            (; MECHANISM = "AMQPLAIN", LOGIN=RABBITMQ_LOGIN, PASSWORD=RABBITMQ_PASSWORD)
        )
        conn = AMQPClient.connection(; virtualhost="/", host="localhost", port=RABBITMQ_PORT, auth_params)
        @info typeof(AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true))
        rabbitmq_channel[] = AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true)
    end

    v = Pkg.Types.read_project("Project.toml").version
    @info "__init__ SimulationService with Version = $v"
end

#-----------------------------------------------------------------------------# start!
function start!(; host=HOST[], port=PORT[], kw...)
    @info "starting server on $host:$port.  nthreads=$(Threads.nthreads())"
    ENABLE_TDS[] || @warn "TDS is disabled.  Some features will not work."
    stop!()  # Stop server if it's already running
    server_url[] = "http://$host:$port"
    JobSchedulers.scheduler_start()
    JobSchedulers.set_scheduler(max_cpu=JobSchedulers.SCHEDULER_MAX_CPU, max_mem=0.5, update_second=0.05, max_job=5000)
    Oxygen.resetstate()
    Oxygen.@get     "/"                 health
    Oxygen.@get     "/status/{id}"      job_status
    Oxygen.@post    "/{operation_name}" operation
    Oxygen.@post    "/kill/{id}"        job_kill

    # For /docs
    Oxygen.mergeschema(openapi_spec[])

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

#-----------------------------------------------------------------------------# utils
json_header = ["Content-Type" => "application/json"]

get_json(url::String) = JSON3.read(HTTP.get(url, json_header).body)

timestamp() = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")

#-----------------------------------------------------------------------------# job endpoints
get_job(id::String) = JobSchedulers.job_query(jobhash(id))

# Translate our `id` to JobScheduler's `id`
jobhash(id::String) = reinterpret(Int, hash(id))

# translate JobScheduler's `state` to client's `status`
# NOTE: client also has a `:failed` status that indicates the job completed, but with junk results
get_job_status(job::JobSchedulers.Job) =
    job.state == JobSchedulers.QUEUING      ? "queued" :
    job.state == JobSchedulers.RUNNING      ? "running" :
    job.state == JobSchedulers.DONE         ? "complete" :
    job.state == JobSchedulers.FAILED       ? "error" :
    job.state == JobSchedulers.CANCELLED    ? "cancelled" :
    error("Should be unreachable.  Unknown jobstate: $(job.state)")


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
health(::HTTP.Request) = (
    status = "ok",
    RABBITMQ_ENABLED = RABBITMQ_ENABLED[],
    RABBITMQ_ROUTE = RABBITMQ_ROUTE[],
    ENABLE_TDS = ENABLE_TDS[]
)

#-----------------------------------------------------------------------------# OperationRequest
Base.@kwdef mutable struct OperationRequest
    obj::JSON3.Object = JSON3.Object()                      # untouched JSON from request sent by HMI
    id::String = "sciml-$(UUIDs.uuid4())"                   # matches DataServiceModel :id
    operation::Symbol = :unknown                            # :simulate, :calibrate, etc.
    model::Union{Nothing, JSON3.Object} = nothing           # ASKEM Model Representation (AMR)
    models::Union{Nothing, Vector{JSON3.Object}} = nothing  # Multiple models (in AMR)
    timespan::Union{Nothing, NTuple{2, Float64}} = nothing  # (start, end)
    df::Union{Nothing, DataFrame} = nothing                 # dataset (calibrate only)
    result::Any = nothing                                   # store result of job
end

function Base.show(io::IO, o::OperationRequest)
    println(io, "OperationRequest(id=$(repr(o.id)), operation=$(repr(o.operation)))")
end

function OperationRequest(req::HTTP.Request, operation_name::String)
    o = OperationRequest()
    @info "[$(o.id)] OperationRequest recieved to route /$operation_name: $(String(copy(req.body)))"
    o.obj = JSON3.read(req.body)
    o.operation = Symbol(operation_name)
    for (k,v) in o.obj
        if !ENABLE_TDS[] && k in [:model_config_id, :model_config_ids, :dataset]
            @warn "TDS Disabled - ignoring key `$k` from request with id: $(repr(o.id))"
            continue
        end
        k == :model_config_id ? (o.model = get_model(v)) :
        k == :model_config_ids ? (o.models = get_model.(v)) :
        k == :timespan ? (o.timespan = (Float64(v.start), Float64(v.end))) :
        k == :dataset ? (o.df = get_dataset(v)) :
        k == :model ? (o.model = v) :

        # For testing only:
        k == :local_model_configuration_file ? (o.model = JSON.read(v).configuration) :
        k == :local_model_file ? (o.model = JSON3.read(v)) :
        k == :local_csv_file ? (o.df = CSV.read(v, DataFrame)) :
        nothing
    end
    return o
end

function solve(o::OperationRequest)
    callback = get_callback(o)
    T = operations2type[o.operation]
    op = T(o)
    o.result = solve(op; callback)
end

#-----------------------------------------------------------------------------# DataServiceModel
# https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/schemas/simulation.json
# How a model/simulation is represented in TDS
# you can HTTP.get("$TDS_URL/simulation") and the JSON3.read(body, DataServiceModel)
Base.@kwdef mutable struct DataServiceModel
    # Required
    id::String = ""                                         # matches with our `id`
    engine::String = "sciml"                                # (ignore) TDS supports multiple engine.  We are the `sciml` engine.
    type::String = ""                                       # :calibration, :calibration_simulation, :ensemble, :simulation
    execution_payload::JSON3.Object = JSON3.Object()        # untouched JSON from request sent by HMI
    workflow_id::String = "IGNORED"                         # (ignore)
    # Optional
    name::Union{Nothing, String} = nothing                  # (ignore)
    description::Union{Nothing, String} = nothing           # (ignore)
    timestamp::Union{Nothing, DateTime} = nothing           # (ignore?)
    result_files::Union{Nothing, Vector{String}} = nothing  # URLs of result files in S3
    status::Union{Nothing, String} = "queued"               # queued|running|complete|error|cancelled|failed"
    reason::Union{Nothing, String} = nothing                # why simulation failed (returned junk results)
    start_time::Union{Nothing, DateTime} = nothing          # when job started
    completed_time::Union{Nothing, DateTime} = nothing      # when job completed
    user_id::Union{Nothing, Int64} = nothing                # (ignore)
    project_id::Union{Nothing, Int64} = nothing             # (ignore)
end

# For JSON3 read/write
StructTypes.StructType(::Type{DataServiceModel}) = StructTypes.Mutable()

# PIRACY to fix JSON3.read(str, DataServiceModel)
JSON3.Object(x::AbstractDict) = JSON3.read(JSON3.write(x))

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

#-----------------------------------------------------------------------------# publish_to_rabbitmq
# published as JSON3.write(content)
function publish_to_rabbitmq(content)
    if !RABBITMQ_ENABLED[]
        @warn "RabbitMQ disabled - `publish_to_rabbitmq` with content $(JSON3.write(content))"
        return content
    end
    json = Vector{UInt8}(codeunits(JSON3.write(content)))
    message = AMQPClient.Message(json, content_type="application/json")
    AMQPClient.basic_publish(rabbitmq_channel[], message; exchange="", routing_key=SIMSERVICE_RABBITMQ_ROUTE)
end
publish_to_rabbitmq(; kw...) = publish_to_rabbitmq(Dict(kw...))


#----------------------------------------------------------------------------# TDS GET interactions
# Each function in this section assumes ENABLE_TDS=true

function DataServiceModel(id::String)
    @assert ENABLE_TDS[]
    @info "DataServiceModel($(repr(id)))"
    check = (_, e) -> e isa HTTP.Exceptions.StatusError && ex.status == 404
    delays = fill(1, TDS_RETRIES[])
    res = retry(() -> HTTP.get("$(TDS_URL[])/simulations/$id"); delays, check)()
    return JSON3.read(res.body, DataServiceModel)
end

function get_model(id::String)
    @assert ENABLE_TDS[]
    @info "get_model($(repr(id)))"
    get_json("$(TDS_URL[])/model_configurations/$id").configuration
end

function get_dataset(obj::JSON3.Object)
    @assert ENABLE_TDS[]
    @info "get_dataset with obj = $(JSON3.write(obj))"
    tds_url = "$(TDS_URL[])/datasets/$(obj.id)/download-url?filename=$(obj.filename)"
    s3_url = get_json(tds_url).url
    df = CSV.read(download(s3_url), DataFrame)
    return haskey(obj, :mappings) ?
        rename!(df, Dict{String,String}(obj.mappings)) :
        df
end


#-----------------------------------------------------------------------# TDS PUT/POST interactions
# Functions in this section:
# - If ENABLE_TDS=true, they PUT/POST a JSON payload to the TDS
# - If ENABLE_TDS=false, they log and return the JSON payload they would have PUT/POST

# initialize the DataServiceModel in TDS: POST /simulations/{id}
function create(o::OperationRequest)
    @info "create: $o"
    m = DataServiceModel(o)
    body = JSON3.write(m)
    if !ENABLE_TDS[]
         @warn "TDS disabled - `create` $o: $body"
         return body
    end
    HTTP.post("$(TDS_URL[])/simulations/", json_header; body)
end

# update the DataServiceModel in TDS: PUT /simulations/{id}
# kw args and their types much match field::fieldtype in DataServiceModel
function update(o::OperationRequest; kw...)
    @info "update $o"
    if !ENABLE_TDS[]
        @warn "TDS disabled - `update` $o: $(JSON3.write(kw))"
        return JSON3.write(kw)
    end
    m = DataServiceModel(o.id)
    for (k,v) in kw
        isnothing(v) ?
            setproperty!(m, k, v) :
            setproperty!(m, k, Base.nonnothingtype(fieldtype(DataServiceModel, k))(v))
    end
    HTTP.put("$(TDS_URL[])/simulations/$(o.id)", json_header; body=JSON3.write(m))
end

function complete(o::OperationRequest)
    isnothing(o.result) && error("No result.  Run `solve(o::OperationRequest)` first.")
    @info "complete $o"

    if o.result isa DataFrame
        # DataFrame uploaded as CSV file
        # TODO: Is this rename! still required??
        for nm in names(o.result)
            rename!(o.result, nm => replace(nm, "(t)" => ""))
        end
        io = IOBuffer()
        CSV.write(io, o.result)
        body = String(take!(io))
        filename = "result.csv"
        header = ["Content-Type" => "text/csv"]
    else
        # everything else as JSON file
        body = JSON3.write(o.result)
        filename = "result.json"
        header = json_header
    end
    if !ENABLE_TDS[]
        @warn "TDS disabled - `complete` $o: summary(body) = $(summary(body))"
        return body
    end

    tds_url = "$(TDS_URL[])/simulations/$(o.id)/upload-url?filename=$filename"
    s3_url = get_json(tds_url).url
    HTTP.put(s3_url, header; body=body)
    update(o; status = "complete", completed_time = timestamp(), result_files = [s3_url])
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
    @info "Creating OperationRequest from POST to route $operation_name"
    o = OperationRequest(request, operation_name)  # 1, 3
    create(o)  # 2
    job = JobSchedulers.Job(
        @task begin
            try
                update(o; status = "running", start_time = timestamp()) # 4
                solve(o) # 5
                complete(o)  # 6, 7
            catch ex
                update(o; status = "error", reason = string(ex))
                rethrow(ex)
            end
        end
    )
    job.id = jobhash(o.id)
    last_operation[] = o
    last_job[] = job
    @info "Submitting job..."
    JobSchedulers.submit!(job)

    body = JSON3.write((; simulation_id = o.id))
    return HTTP.Response(201, ["Content-Type" => "application/json; charset=utf-8"], body; request)
end

#-----------------------------------------------------------------------------# operations.jl
include("operations.jl")


end # module
