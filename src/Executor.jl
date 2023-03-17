"""
Interface for relevant ASKEM simulation libraries    
"""
module Executor

import AlgebraicPetri: LabelledPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, @post, @get
import CSV: write 
import HTTP: Request
import HTTP.Exceptions: StatusError
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./deterministic.jl"); import .Deterministic: forecast

"""
Schedule a sim run
"""
function start_run(func)
    # TODO(five): Spawn remote workers and run jobs on them
    # TODO(five): Handle Python so a probabilistic case can work
    sim_run = Job(
        @task(func);
        priority = 5
    )
    submit!(sim_run)
    sim_run.id
end

"""
Transform request body into splattable dict for kwargs only functions    
"""
function get_args(req::Request)::Dict{Symbol,Any}
    args = json(req, Dict{Symbol, Any})
    if !haskey(args, :petri)
        args[:petri] = parse_json_acset(LabelledPetriNet, args[:petri])
    end
    if !haskey(args, :tspan)
        args[:tspan] = Tuple(args[:tspan])
    end
    args
end


"""
Hydrates a given function with a job
"""
function fill_job(func)
    function job_injected_func(_, id::Int64)
        job = job_query(id)
        if isnothing(job)
            return StatusError(404, "GET", "GET", "Job does not exist")
        end
        func(job)
    end
end

"""
Find sim run and request a job with the given args    
"""
function make_deterministic_run(req::Request, name::String)
    valid_funcs = Dict("forecast"=>forecast)
    if !haskey(valid_funcs, name)
        return StatusError(404, "GET", "GET", "Function not found")
    end
    chosen_sim = valid_funcs[name]
    args = get_args(req)
    # TODO(five): Transform request into labelled array splatted in func
    # TODO(five): Support more return types other than CSV
    # TODO(five): Write to remove server
    start_run(()->(
        sol = chosen_sim(; args...);
        io = IOBuffer();
        write(io, sol);
        String(take!(io))
    ))
end

"""
Retrieve results of a sim run    
"""
function retrieve_results(job)
    if job.state != :done
        return StatusError(400, "GET", "GET", "Tried to access incomplete sim run")
    end
    result(job)
end

"""
Specify endpoint to function mappings
"""
function register!()
    @post "/run/deterministic/{name}" make_deterministic_run
    @get "/status/{id}" fill_job((job)->job.state)
    @get "/result/{id}" fill_job(retrieve_results)
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

end # module Executor
