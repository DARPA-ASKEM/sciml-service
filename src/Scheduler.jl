"""
Interface for relevant ASKEM simulation libraries    
"""
module Scheduler

import AlgebraicPetri: LabelledPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, @post, @get
import CSV: write 
import DataFrames: DataFrame
import HTTP: Request
import HTTP.Exceptions: StatusError
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./SciMLInterface.jl"); import .SciMLInterface: sciml_operations, conversions_for_valid_inputs

"""
Schedule a sim run
"""
function start_run!(prog::Function, args::Dict{Symbol, Any})
    # TODO(five): Spawn remote workers and run jobs on them
    # TODO(five): Handle Python so a probabilistic case can work
    sim_run = Job(@task(prog(;args...)))
    submit!(sim_run)
    sim_run.id
end

"""
Transform request body into splattable dict with correct types   
"""
function get_args(req::Request)::Dict{Symbol,Any}
    args = json(req, Dict{Symbol, Any})
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
    # TODO(five): Support more return types other than CSV i.e. write more methods
    function prepare_output(dataframe::DataFrame)
        io = IOBuffer()
        # TODO(five): Write to remote server
        write(io, dataframe)
        String(take!(io))
    end
    if !haskey(sciml_operations, Symbol(operation))
        return StatusError(404, "GET", "GET", "Function not found")
    end
    prog = prepare_output ∘ sciml_operations[Symbol(operation)]
    args = get_args(req)
    start_run!(prog, args)
end

"""
Get status of sim
"""
function retrieve_job(_, id::Int64, element::String)
    job = job_query(id)
    if isnothing(job)
        return StatusError(404, "GET", "GET", "Job does not exist")
    end
    if element == "status"
        return Dict("status"=>job.state)
    elseif element == "result"
        if job.state == :done
            return result(job)
        else
            return StatusError(400, "GET", "GET", "Job has not completed")
        end
    else
        return StatusError(404, "GET", "GET", "Element does not exist")
    end
end

function health_check()
    return "simulation scheduler is running"
end

"""
Specify endpoint to function mappings
"""
function register!()
    @get "/" health_check
    @post "/calls/{operation}" make_deterministic_run
    @get  "/runs/{id}/{element}" retrieve_job
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
