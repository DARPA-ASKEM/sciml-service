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
import DataFrames: DataFrame
import HTTP: Request, Response
import JobSchedulers: scheduler_start, set_scheduler, scheduler_stop, submit!, job_query, result, generate_id, update_queue!, Job, JobSchedulers

include("./contracts/Interface.jl"); import .Interface: get_operation, use_operation, conversions_for_valid_inputs, Context
include("./service/Service.jl"); import .Service.ArgIO: prepare_output, prepare_input; import .Service.Queuing: publish_to_rabbitmq
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
Generate the task to run with the correct context    
"""
function contextualize_prog(context)
    prepare_output(context) ∘ use_operation(context) ∘ prepare_input(context)
end

"""
Schedule a sim run given an operation
"""
function make_deterministic_run(req::Request, operation::String)
    # TODO(five): Spawn remote workers and run jobs on them
    # TODO(five): Handle Python so a probabilistic case can work
    if isnothing(get_operation(operation))
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Operation not found"
        )
    end

    publish_hook = settings["SHOULD_LOG"] ? publish_to_rabbitmq : (args...) -> nothing

    context = Context(
        generate_id(),
        publish_hook,  
        Symbol(operation),
    )
    prog = contextualize_prog(context)
    sim_run = Job(@task(prog(req)))
    sim_run.id = context.job_id
    submit!(sim_run)
    Response(
        201,
        ["Content-Type" => "application/json; charset=utf-8"],
        body=JSON.write("id" => sim_run.id)
    )
end

"""
Get status of sim
"""
function retrieve_job(_, id::Int64, element::String)
    job = job_query(id)
    if isnothing(job)
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Job does not exist"
        )
    end
    if element == "status"
        return Dict("status" => job.state)
    elseif element == "result"
        if job.state == :done
            return result(job)
        else
            return Response(
                400,
                ["Content-Type" => "text/plain; charset=utf-8"],
                body="Job has not completed"
            )
        end
    else
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Element not found"
        )
    end
end




"""
Specify endpoint to function mappings
"""
function register!()
    @get "/" health_check

    @get "/runs/{id}/{element}" retrieve_job

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
