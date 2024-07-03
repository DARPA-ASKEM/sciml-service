module SimulationService

import PrecompileTools: @recompile_invalidations, @compile_workload

@recompile_invalidations begin
import AMQPClient
import Base64
import CSV
import DataFrames: DataFrame, names, rename!
import Dates: Dates, DateTime, now, UTC
import DifferentialEquations
import Downloads: download
import Distributions
import EasyModelAnalysis
import HTTP
import InteractiveUtils: subtypes
import JobSchedulers
import JSON3
import JSONSchema
import LinearAlgebra: norm
import MathML
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem, ODEProblem, ODESolution, structural_simplify, unknowns, observed, parameters
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
import MLStyle
import Catlab
import RegNets
using Latexify
end

export start!, stop!

#-----------------------------------------------------------------------------# __init__
const rabbitmq_channel = Ref{Any}()
const openapi_spec = Ref{Dict}()
const simulation_schema = Ref{JSON3.Object}()
const petrinet_schema = Ref{JSON3.Object}()
const petrinet_JSONSchema_object = Ref{JSONSchema.Schema}()
const server_url = Ref{String}()
const mock_tds = Ref{Dict{String, Dict{String, JSON3.Object}}}()  # e.g. "model" => "model_id" => model

#-----# Environmental Variables:
# Server configuration
const HOST = Ref{String}()
const PORT = Ref{Int}()
# Terrarium Data Service (TDS)
const ENABLE_TDS = Ref{Bool}()
const TDS_URL = Ref{String}()
const TDS_USER = Ref{String}()
const TDS_PASSWORD = Ref{String}()
const TDS_RETRIES = Ref{Int}()
# RabbitMQ (Note: assumes running on localhost)
const RABBITMQ_ENABLED = Ref{Bool}()
const RABBITMQ_LOGIN = Ref{String}()
const RABBITMQ_PASSWORD = Ref{String}()
const RABBITMQ_ROUTE = Ref{String}()
const RABBITMQ_HOST = Ref{String}()
const RABBITMQ_PORT = Ref{Int}()
const RABBITMQ_SSL = Ref{Bool}()

const queue_dict = Dict{String, String}()

const basic_auth_header = Ref{Pair{String, String}}()

function __init__()
    if Threads.nthreads() == 1
        @warn "SimulationService.jl expects `Threads.nthreads() > 1`.  Use e.g. `julia --threads=auto`."
    end
    openapi_spec[] = YAML.load_file(download("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml"))
    simulation_schema[] = get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/schemas/simulation.json")
    petrinet_schema[] = get_json("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/petrinet_schema.json")
    petrinet_JSONSchema_object[] = JSONSchema.Schema(petrinet_schema[])

    HOST[] = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
    PORT[] = parse(Int, get(ENV, "SIMSERVICE_PORT", "8080"))
    ENABLE_TDS[] = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true"
    TDS_URL[] = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:3000")
    TDS_USER[] = get(ENV, "SIMSERVICE_TDS_USER", "user")
    TDS_PASSWORD[] = get(ENV, "SIMSERVICE_TDS_PASSWORD", "password")
    TDS_RETRIES[] = parse(Int, get(ENV, "SIMSERVICE_TDS_RETRIES", "10"))
    RABBITMQ_ENABLED[] = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true" && ENABLE_TDS[]
    RABBITMQ_LOGIN[] = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
    RABBITMQ_PASSWORD[] = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
    RABBITMQ_ROUTE[] = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "sciml-queue")
    RABBITMQ_HOST[] = get(ENV, "SIMSERVICE_RABBITMQ_HOST", "localhost")
    RABBITMQ_PORT[] = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))
    RABBITMQ_SSL[] = get(ENV, "SIMSERVICE_RABBITMQ_SSL", "false") == "true"

    if RABBITMQ_ENABLED[]
        auth_params = Dict{String,Any}(
            ("MECHANISM" => "AMQPLAIN", "LOGIN" => RABBITMQ_LOGIN[], "PASSWORD" => RABBITMQ_PASSWORD[])
        )

        amqps = nothing
        if RABBITMQ_SSL[]
            amqps = AMQPClient.amqps_configure()
        end

        conn = AMQPClient.connection(; virtualhost="/", host=RABBITMQ_HOST[], port=RABBITMQ_PORT[], auth_params, amqps)

        rabbitmq_channel[] = AMQPClient.channel(conn, AMQPClient.UNUSED_CHANNEL, true)
        AMQPClient.queue_declare(rabbitmq_channel[], RABBITMQ_ROUTE[];)
    end

    encoded_credentials = Base64.base64encode("$(TDS_USER[]):$(TDS_PASSWORD[])")
    basic_auth_header[] = "Authorization" => "Basic $encoded_credentials"

    v = Pkg.Types.read_project(joinpath(@__DIR__, "..", "Project.toml")).version
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


    Oxygen.@get     "/model-equation/{id}"  modelEquation
    Oxygen.@post    "/model-equation"       modelToEquation

    Oxygen.@get     "/health"               health
    Oxygen.@get     "/status/{id}"          job_status
    Oxygen.@post    "/kill/{id}"            job_kill

    Oxygen.@post    "/simulate"             req -> operation(req, "simulate")
    Oxygen.@post    "/calibrate"            req -> operation(req, "calibrate")
    Oxygen.@post    "/ensemble-simulate"    req -> operation(req, "ensemble-simulate")
    Oxygen.@post    "/ensemble-calibrate"   req -> operation(req, "ensemble-calibrate")

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
json_content_header = "Content-Type" => "application/json"
snake_case_header = "X-Enable-Snake-Case" => ""

get_json(url::String) = JSON3.read(HTTP.get(url, [json_content_header]).body)


timestamp() = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")

# Run some code with a running server
function with_server(f::Function; wait=1)
    try
        start!()
        sleep(wait)
        url = SimulationService.server_url[]
        f(url)
    catch ex
        rethrow(ex)
    finally
        stop!()
    end
end

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
        # TODO: update simulation model in TDS with status="cancelled"
        JobSchedulers.cancel!(job)
        return HTTP.Response(200)
    end
end

# GET /model-equation/{id}
function modelEquation(::HTTP.Request, id::String)
    @assert ENABLE_TDS[]

    tds_url = "$(TDS_URL[])/models/$id"
    model_json = JSON3.read(HTTP.get(tds_url, [basic_auth_header[], json_content_header, snake_case_header]).body)
    sys = amr_get(model_json, ODESystem)

    model_latex = latexify(sys)
    return Dict([
        (:latex, model_latex.s)
    ])
end

# POST /model-equation
function modelToEquation(req::HTTP.Request)
    amrJSON = JSON3.read(req.body)
    sys = amr_get(amrJSON, ODESystem)
    model_latex = latexify(sys)
    return Dict([
        (:latex, model_latex.s)
    ])
end


#-----------------------------------------------------------------------------# health: GET /
function health(::HTTP.Request)
    version_filepath = normpath(joinpath(@__FILE__,"../../.version"))
    version =
        if ispath(version_filepath)
            version_filepath |> strip ∘ String ∘ read ∘ open
        else
            "unknown"
        end
    (
        status = "ok",
        git_sha = version,
        RABBITMQ_ENABLED = RABBITMQ_ENABLED[],
        RABBITMQ_ROUTE = RABBITMQ_ROUTE[],
        ENABLE_TDS = ENABLE_TDS[]
    )
end

#-----------------------------------------------------------------------------# OperationRequest
Base.@kwdef mutable struct OperationRequest
    obj::JSON3.Object = JSON3.Object()                      # untouched JSON from request sent by HMI
    id::String = "$(UUIDs.uuid4())"                   # matches DataServiceModel :id
    route::String = "unknown"                               # :simulate, :calibrate, etc.
    model::Union{Nothing, JSON3.Object} = nothing           # ASKEM Model Representation (AMR)
    models::Union{Nothing, Vector{JSON3.Object}} = nothing  # Multiple models (in AMR)
    timespan::Union{Nothing, NTuple{2, Float64}} = nothing  # (start, end)
    df::Union{Nothing, DataFrame} = nothing                 # dataset (calibrate only)
    result::Any = nothing                                   # store result of job
end

function get_callback(o::OperationRequest)
    optype = route2operation_type[o.route]
    get_callback(o,optype)
end

function Base.show(io::IO, o::OperationRequest)
    println(io, "OperationRequest(id=$(repr(o.id)), route=$(repr(o.route)))")
end

function OperationRequest(req::HTTP.Request, route::String)
    o = OperationRequest()
    @info "[$(o.id)] OperationRequest received to route /$route: $(String(copy(req.body)))"
    o.obj = JSON3.read(req.body)
    o.route = route

    # Use custom MQ if specified
    params = HTTP.queryparams(req)
    if haskey(params, "queue")
        queue_name = params["queue"]
        queue_dict[o.id] = queue_name
        AMQPClient.queue_declare(rabbitmq_channel[], queue_name; passive=true)
    end

    for (k,v) in o.obj
        @info "k : $k"
        # Skip keys using TDS if !ENABLE_TDS
        if !ENABLE_TDS[] && k in [:model_config_id, :model_config_ids, :dataset, :model_configs]
            @warn "TDS Disabled - ignoring key `$k` from request with id: $(repr(o.id))"
            continue
        end
        k == :model_config_id ? (o.model = get_model(v)) :
        k == :model_config_ids ? (o.models = get_model.(v)) :
        k == :timespan ? (o.timespan = (Float64(v.start),Float64(v.end))) :
        k == :dataset ? (o.df = get_dataset(v)) :
        k == :model ? (o.model = v) :

        # For ensemble, we get objects with {id, solution_mappings, weight}
        k == :model_configs ? (o.models = [get_model(m.id) for m in v]) :

        # For testing only:
        k == :local_model_configuration_file ? (o.model = JSON3.read(v).configuration) :
        k == :local_model_file ? (o.model = JSON3.read(v)) :
        k == :local_csv_file ? (o.df = CSV.read(v, DataFrame)) :

        # For testing from simulation-integration URLs
        k == :model_file_url ? (o.model = JSON3.read(HTTP.get(v).body)) :
        k == :model_file_urls ? (o.models = [JSON3.read(HTTP.get(m).body) for m in v]) :
        k == :configuration_file_url ? (o.model = JSON3.read(HTTP.get(v).body).configuration) :
        k == :configuration_file_urls ? (o.models = [JSON3.read(HTTP.get(m).body).configuration for m in v]) :
        k == :dataset_url ? (o.df = CSV.read((HTTP.get(v).body), DataFrame)) :
        nothing
    end

    # Checks if the JSON model is valid against the petrinet schema
    # If not valid, produces a warning saying why
    if !isnothing(o.model)
        valid_against_schema = JSONSchema.validate(petrinet_JSONSchema_object[],o.model)
        if !isnothing(valid_against_schema)
            @warn "Object not valid against schema: $(valid_against_schema)"
        end
    end

    if !isnothing(o.models)
        for model in o.models
            valid_against_schema = JSONSchema.validate(petrinet_JSONSchema_object[],model)
            if !isnothing(valid_against_schema)
                @warn "Object not valid against schema: $(valid_against_schema)"
            end
        end
    end

    return o
end



function solve(o::OperationRequest)
    callback = get_callback(o)
    T = route2operation_type[o.route]
    op = T(o)
    o.result = solve(op, callback = callback)
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
    workflow_id::Union{Nothing, String} = nothing           # (ignore)
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
# TODO make upstream issue in JSON3
JSON3.Object(x::AbstractDict) = JSON3.read(JSON3.write(x))

# translate route (in OpenAPI spec) to type (in TDS)
#   route: https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml
#   type: https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/schemas/simulation.json
route2type = Dict(
    "simulate" => "simulation",
    "calibrate" => "calibration",
    "ensemble-simulate" => "ensemble",
    "ensemble-calibrate" => "ensemble"
)

# Initialize a DataServiceModel
function DataServiceModel(o::OperationRequest)
    m = DataServiceModel()
    m.id = o.id
    m.type = route2type[o.route]
    m.execution_payload = o.obj
    return m
end

#-----------------------------------------------------------------------------# debug_data
# For debugging: Try to recreate the OperationRequest from TDS data
# NOTE: TDS does not save which route was used...
function OperationRequest(m::DataServiceModel)
    req = HTTP.Request("POST", "", [], JSON3.write(m.execution_payload))
    return OperationRequest(req, "DataServiceModel: $(m.type)")
end

# Dump all the info we can get about a simulation `id`
function debug_data(id::String)
    @assert ENABLE_TDS[]
    data_service_model = DataServiceModel(id::String)
    request_json = data_service_model.execution_payload
    amr = get_model(data_service_model.execution_payload.model_config_id)
    operation_request = OperationRequest(data_service_model)
    job = get_job(id)
    return (; request_json, amr, data_service_model, operation_request, job)
end

#-----------------------------------------------------------------------------# publish_to_rabbitmq
# published as JSON3.write(content)
function publish_to_rabbitmq(content)
    if !RABBITMQ_ENABLED[]
        # stop printing content for now, getting to be too much
        @warn "RabbitMQ disabled - `publish_to_rabbitmq`" #with content $(JSON3.write(content))"
        return content
    end
    json = Vector{UInt8}(codeunits(JSON3.write(content)))
    message = AMQPClient.Message(json, content_type="application/json")

    route = RABBITMQ_ROUTE[]
    if haskey(queue_dict, content[:id])
        route = queue_dict[content[:id]]
    end

    AMQPClient.basic_publish(rabbitmq_channel[], message; exchange="", routing_key=route)
end
publish_to_rabbitmq(; kw...) = publish_to_rabbitmq(Dict(kw...))


#----------------------------------------------------------------------------# TDS GET interactions
# Each function in this section assumes ENABLE_TDS=true

function DataServiceModel(id::String)
    @assert ENABLE_TDS[]
    @info "DataServiceModel($(repr(id)))"
    check = (_, e) -> e isa HTTP.Exceptions.StatusError && ex.status == 404
    delays = fill(1, TDS_RETRIES[])

    res = retry(() -> HTTP.get("$(TDS_URL[])/simulations/$id", [basic_auth_header[], snake_case_header, json_content_header]); delays, check)()
    return JSON3.read(res.body, DataServiceModel)
end

function get_model(id::String)
    @assert ENABLE_TDS[]
    @info "get_model($(repr(id)))"

    tds_url = "$(TDS_URL[])/model-configurations/as-configured-model/$id"

    JSON3.read(HTTP.get(tds_url, [basic_auth_header[], json_content_header, snake_case_header]).body)
end

function get_dataset(obj::JSON3.Object)
    @assert ENABLE_TDS[]
    @info "get_dataset with obj = $(JSON3.write(obj))"

    tds_url = "$(TDS_URL[])/datasets/$(obj.id)/download-url?filename=$(obj.filename)"

    s3_url = JSON3.read(HTTP.get(tds_url, [basic_auth_header[], json_content_header, snake_case_header]).body).url
    df = CSV.read(download(s3_url), DataFrame)

    for (k,v) in get(obj, :mappings, Dict())
        @info "`get_dataset` (dataset id=$(repr(obj.id))) rename! $k => $v"
        if Symbol(k) != :tstep
            rename!(df, k => v)
        else
            rename!(df, v => "timestamp") # hack to get df in our "schema"
        end
    end

    @info "get_dataset (id=$(repr(obj.id))) with names: $(names(df))"
    return df
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


    new_id = JSON3.read(HTTP.post("$(TDS_URL[])/simulations", [basic_auth_header[], json_content_header, snake_case_header]; body).body).id
    o.id = new_id
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


    HTTP.put("$(TDS_URL[])/simulations/$(o.id)", [basic_auth_header[], json_content_header, snake_case_header]; body=JSON3.write(m))
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
        header = [json_content_header]
    end
    if !ENABLE_TDS[]
        @warn "TDS disabled - `complete` $o: summary(body) = $(summary(body))"
        return body
    end

    tds_url = "$(TDS_URL[])/simulations/$(o.id)/upload-url?filename=$filename"

    s3_url = JSON3.read(HTTP.get(tds_url, [basic_auth_header[], json_content_header, snake_case_header]).body).url

    HTTP.put(s3_url, header; body=body)
    update(o; status = "complete", completed_time = timestamp(), result_files = [filename])

    delete!(queue_dict, o.id)
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
function operation(request::HTTP.Request, route::String)
    @info "Creating OperationRequest from POST to route $route"
    o = OperationRequest(request, route)  # 1, 3
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
    @info "Submitting job $(o.id)"
    JobSchedulers.submit!(job)

    body = JSON3.write((; simulation_id = o.id))
    return HTTP.Response(201, ["Content-Type" => "application/json; charset=utf-8"], body; request)
end

#---------------------------------------------------------------------------s--# operations.jl
include("operations.jl")
include("model_parsers/RegNets.jl")
include("model_parsers/StockFlow.jl")
get(ENV, "SIMSERVICE_PRECOMPILE", "true") == "true" && include("precompile.jl")


#-----------------------------------------------------------------------------# PackageCompilers.jl entry
function julia_main()::Cint
    start!();
    while true sleep(10000) end
    return 0
end


end # module SimulationService
