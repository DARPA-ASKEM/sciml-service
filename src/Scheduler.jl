"""
Interface for relevant ASKEM simulation libraries    
"""
module Scheduler

__precompile__(false)

import AlgebraicPetri: LabelledPetriNet
import Symbolics
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, setschema, @post, @get
import SwaggerMarkdown: build, @swagger, OpenAPI, validate_spec, openApiToDict, DOCS
import YAML: load
import CSV: write
import JSON3
import DataFrames: DataFrame
import HTTP: Request, Response
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./SciMLInterface.jl")
import .SciMLInterface: sciml_operations, use_operation, conversions_for_valid_inputs

"""
Schedule a sim run
"""
function start_run!(prog::Function, args::Dict{Symbol,Any})
    # TODO(five): Spawn remote workers and run jobs on them
    # TODO(five): Handle Python so a probabilistic case can work
    sim_run = Job(@task(prog(; args...)))
    submit!(sim_run)
    Response(
        201,
        ["Content-Type" => "application/json; charset=utf-8"],
        body=JSON3.write("id" => sim_run.id)
    )
end

"""
Transform request body into splattable dict with correct types   
"""
function get_args(req::Request)::Dict{Symbol,Any}
    args = json(req, Dict{Symbol,Any})
    function coerce!(key) # Is there a more idiomatic way of doing this
        if haskey(args, key)
            args[key] = conversions_for_valid_inputs[key](args[key])
        end
    end
    coerce!.(keys(conversions_for_valid_inputs))
    args
end

"""
Find sim run and request a job with the given args    
"""
function make_deterministic_run(req::Request, operation::String)
    # TODO(five): Handle output on a less case by case basis
    function prepare_output(dataframe::DataFrame)
        io = IOBuffer()
        # TODO(five): Write to remote server
        write(io, dataframe)
        String(take!(io))
    end
    function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}})
        nan_to_nothing(value) = isnan(value) ? nothing : value
        Dict(key => nan_to_nothing(value) for (key, value) in params)
    end
    if !haskey(sciml_operations, Symbol(operation))
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Operation not found"
        )
    end
    prog = prepare_output ∘ use_operation(Symbol(operation))
    args = get_args(req)
    start_run!(prog, args)
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
    @get "/" () -> "simulation scheduler is running"

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
    /calls/forecast:
     post:
       summary: Simulation forecast
       description: Create forecast job
       requestBody:
         description: Arguments to pass into forecast function 
         required: true
         content:
             application/json:
                 schema: 
                     type: object
                     properties:
                         petri:
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
                         t:
                             type: array
                             items:
                                 type: number
                     required:
                         - petri
                         - initials
                         - params
                         - tspan
                     example:
                         petri: "{}"
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
         description: Arguments to pass into forecast function. `t` must contain every timestep used in `data`. 
         required: true
         content:
             application/json:
                 schema: 
                     type: object
                     properties:
                         petri:
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
                         timesteps:
                             type: array
                             items:
                                 type: number
                         data:
                             type: object
                             properties:
                                 column:
                                     type: array
                                     items:
                                        type: number
                     required:
                         - petri
                         - initials
                         - params
                         - tspan
                     example:
                         petri: "{}"
                         initials: {"compartment_a": 100.1, "compartment_b": 200} 
                         params: {"alpha": 0.5, "beta": 0.1}
                         timesteps: []
                         data: {}
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
function run!()
    resetstate()
    register!()
    if Threads.nthreads() > 1
        scheduler_start()
        set_scheduler(
            max_cpu=0.5,
            max_mem=0.5,
            update_second=0.05,
            max_job=5000,
        )
        serveparallel(host="0.0.0.0")
    else
        println("WARNING: The server is not parallelized. You may need to start the REPL like `julia --threads 5`")
        scheduler_start()
        serve(host="0.0.0.0")
    end
end

end # module Scheduler
