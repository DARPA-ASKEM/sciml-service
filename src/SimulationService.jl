"""
Interface for relevant ASKEM simulation libraries    
"""
module SimulationService 

import AlgebraicPetri: LabelledPetriNet
import Symbolics
import Oxygen: serveparallel, resetstate, json, setschema, terminate, @post, @get
import SwaggerMarkdown: build, @swagger, OpenAPI, validate_spec, openApiToDict, DOCS
import YAML
import JSON3 as JSON
import JobSchedulers: scheduler_start, set_scheduler, scheduler_stop, submit!, job_query, result, generate_id, update_queue!, Job, JobSchedulers

include("./service/Service.jl")
import .Service: make_deterministic_run, retrieve_job
include("./Settings.jl"); import .Settings: settings

export start!, stop!

OPENAPI_SPEC = "paths.yaml"

"""
Print out settings
"""
function health_check()
    tds_url = settings["TDS_URL"]
    enable_remote = settings["ENABLE_REMOTE_DATA_HANDLING"]
    mq_route = settings["RABBITMQ_ROUTE"]

    return "Simulation-service. TDS_URL=$tds_url, RABBITMQ_ROUTE=$mq_route, ENABLE_REMOTE_DATA_HANDLING=$enable_remote"
end


"""
Specify endpoint to function mappings
"""
function register!()
    @get "/" health_check
    @get "/{element}/{id}" retrieve_job
    @post "/{operation}" make_deterministic_run

    info = Dict("title" => "Simulation Service", "version" => "0.6.0")
    openAPI = OpenAPI("3.0.0", info)
    openAPI.paths = YAML.load_file(OPENAPI_SPEC)
    documentation = build(openAPI)
    setschema(documentation)
end

"""
Load API endpoints and start listening for sim run jobs
"""
function start!()
    resetstate()
    register!()
    if Threads.nthreads() > 1
        set_scheduler(
            max_cpu=0.5,
            max_mem=0.5,
            update_second=0.05,
            max_job=5000,
        )
        scheduler_start()
        serveparallel(host="0.0.0.0", async=true)
    else
        throw("The server is not parallelized. You need to start the REPL like `julia --threads 5`")
    end
    nothing
end

"""
Shutdown server    
"""
function stop!()
    scheduler_stop()
    terminate()
end

end # module SimulationService
