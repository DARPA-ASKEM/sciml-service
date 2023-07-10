module SimulationService

using Oxygen: Oxygen
using HTTP: HTTP
using JSON3: JSON3

export start!, stop!

#-----------------------------------------------------------------------------# start!
function start!(; host=SIMSERVICE_HOST, port=SIMSERVICE_PORT, kw...)
    stop!()
    Threads.nthreads() > 1 || error("Server is not parallelized. Start the REPL with `julia --threads=auto`.")
    Oxygen.resetstate()
    Oxygen.@get "/" health
    Oxygen.@post "/simulate" req -> simulate(process_request(req))
    Oxygen.@post "/calibrate" req -> calibrate(process_request(req))
    Oxygen.@post "/ensemble" req -> ensemble(process_request(req))
    Oxygen.serveparallel(; host, port, kw...)
end

#-----------------------------------------------------------------------------# stop!
function stop!()
    Oxygen.terminate()
end

#-----------------------------------------------------------------------------# settings
# server
SIMSERVICE_HOST                 = get(ENV, "SIMSERVICE_HOST", "0.0.0.0")
SIMSERVICE_PORT                 = parse(Int, get(ENV, "SIMSERVICE_PORT", "8000"))

# rabbitmq
SIMSERVICE_RABBITMQ_ENABLED     = get(ENV, "SIMSERVICE_RABBITMQ_ENABLED", "false") == "true"
SIMSERVICE_RABBITMQ_LOGIN       = get(ENV, "SIMSERVICE_RABBITMQ_LOGIN", "guest")
SIMSERVICE_RABBITMQ_PASSWORD    = get(ENV, "SIMSERVICE_RABBITMQ_PASSWORD", "guest")
SIMSERVICE_RABBITMQ_ROUTE       = get(ENV, "SIMSERVICE_RABBITMQ_ROUTE", "terarium")
SIMSERVICE_RABBITMQ_PORT        = parse(Int, get(ENV, "SIMSERVICE_RABBITMQ_PORT", "5672"))

# tds
SIMSERVICE_ENABLE_TDS           = get(ENV, "SIMSERVICE_ENABLE_TDS", "true") == "true"
SIMSERVICE_TDS_URL              = get(ENV, "SIMSERVICE_TDS_URL", "http://localhost:8001")


#-----------------------------------------------------------------------------# S3 uploaders
JSON_HEADER = ["Content-Type" => "application/json"]

function get_upload_url(job_id::String, name::String, ext::String)
    url = string(SIMSERVICE_TDS_URL, "/simulations/sciml-$job_id/upload-url?filename=$name.$ext")
    res = HTTP.get(url, JSON_HEADER)
    return JSON3.read(res.body).url
end

# DataFrame -> CSV
# Other -> JSON
function upload(output, job_id::String; name::String="result")
    if SIMSERVICE_ENABLE_TDS
        return @warn "TDS is not enabled.  `output::$(typeof(output))` will not be uploaded.))"
    end
    ext = output isa DataFrame ? "csv" : "json"
    body = output isa DataFrame ? CSV.write(output) : JSON3.write(output)
    url = get_upload_url(job_id, name, ext)
    HTTP.put(url, JSON_HEADER; body)
    return first(split(url, '?'))
end

#-----------------------------------------------------------------------------# /health
function health(::HTTP.Request)
    return (; SIMSERVICE_RABBITMQ_ENABLED, SIMSERVICE_RABBITMQ_ROUTE)
end

#-----------------------------------------------------------------------------# ModelRepresentation
struct ModelRepresentation
    json_obj::JSON3.Object  # Exact JSON object from the request
end

function ModelRepresentation(req::HTTP.Request)
    obj = JSON3.read(req.body)
    ModelRepresentation(obj)
end


#-----------------------------------------------------------------------------# simulate
function simulate(m::ModelRepresentation)
    "TODO"
end

#-----------------------------------------------------------------------------# calibrate
function calibrate(m::ModelRepresentation)
    "TODO"
end

#-----------------------------------------------------------------------------# ensemble
function ensemble(m::ModelRepresentation)
    "TODO"
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

end # module SimulationService
