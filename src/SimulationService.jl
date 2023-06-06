"""
Interface for relevant ASKEM simulation libraries    
"""
module SimulationService 

import AlgebraicPetri: LabelledPetriNet
import Symbolics
import Oxygen: serveparallel, resetstate, json, setschema, terminate, @post, @get
import SwaggerMarkdown: build, @swagger, OpenAPI, validate_spec, openApiToDict, DOCS
import YAML: load
import CSV: write
import JSON3 as JSON
import DataFrames: DataFrame
import HTTP: Request, Response
import JobSchedulers: scheduler_start, set_scheduler, scheduler_stop, submit!, job_query, result, generate_id, update_queue!, Job, JobSchedulers

include("./contracts/Interface.jl"); import .Interface: get_operation, use_operation, conversions_for_valid_inputs, Context
include("./service/Service.jl"); import .Service.ArgIO: prepare_output, prepare_input; import .Service.Queuing: publish_to_rabbitmq
include("./Settings.jl"); import .Settings: settings

export start!, stop!

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
    @swagger """
    /:
     get:
      summary: Healthcheck
      description: A basic healthcheck for the simulation scheduler  
      responses:
         '200':
             description: Returns notice that service has started

    """
    @get "/" health_check

    @swagger """
    /runs/{id}/status:
     get:
       summary: Simulation status
       description: Get status of specified job
       parameters:
         - name: id
           in: path
           required: true
           description: ID of the simulation job
           schema:
             type: number
       responses:
         '200':
             description: JSON containing status of the job
         '404':
             description: Job does not exist
    /runs/{id}/result:
     get:
       summary: Simulation results
       description: Get the resulting CSV from a job
       parameters:
         - name: id
           in: path
           required: true
           description: ID of the simulation job
           schema:
             type: number
       responses:
         '200':
             description: CSV containing timesteps for each compartment
         '400':
             description: Job has not yet completed
         '404':
             description: Job does not exist
    """
    @get "/runs/{id}/{element}" retrieve_job


    @swagger """
    /calls/simulate:
     post:
       summary: Simulation simulate
       description: Create simulate job
       requestBody:
         description: Arguments to pass into simulate function 
         required: true
         content:
             application/json:
                 schema: 
                     type: object
                     properties:
                         model:
                             type: string
                         initials:
                             type: object
                             properties:
                                 compartment:
                                     type: number
                         params:
                             type: object
                             properties:
                                 variable:
                                     type: number
                         tspan:
                             type: array
                             items:
                                 type: number
                     required:
                         - model
                         - initials
                         - params
                         - tspan
                     example:
                         model: "{}"
                         initials: {"compartment_a": 100.1, "compartment_b": 200} 
                         params: {"alpha": 0.5, "beta": 0.1}
                         tspan: [0,20]
       responses:
         '201':
             description: The ID of the job created
    /calls/calibrate:
     post:
       summary: Simulation calibrate
       description: Create calibrate job
       requestBody:
         description: Arguments to pass into simulate function. 
         required: true
         content:
             application/json:
                 schema: 
                     type: object
                     properties:
                         model:
                             type: string
                         initials:
                             type: object
                             properties:
                                 compartment:
                                     type: number
                         params:
                             type: object
                             properties:
                                 variable:
                                     type: number
                         timesteps_column:
                            type: string
                         feature_mappings:
                             type: object
                             properties:
                                 fromkey:
                                     type: array
                                     items:
                                        type: string
                         dataset:
                            type: string
                     required:
                         - model
                         - initials 
                         - params
                         - timesteps_column
                         - feature_mappings
                         - dataset
                     example:
                         model: "{}"
                         initials: {"compartment_a": 100.1, "compartment_b": 200} 
                         params: {"alpha": 0.5, "beta": 0.1}
                         timesteps_column: []
                         feature_mappings: {}
                         dataset: ""
       responses:
         '201':
             description: The ID of the job created
    """
    @post "/calls/{operation}" make_deterministic_run

    info = Dict("title" => "Simulation Service", "version" => "0.1.0")
    openAPI = OpenAPI("3.0.0", info)
    openAPI.paths = load(join(DOCS)) # NOTE: Has to be done manually because it's broken in SwaggerMarkdown
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
