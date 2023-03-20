"""
Interface for relevant ASKEM simulation libraries    
"""
module Executor

import AlgebraicPetri: LabelledPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, @post, @get
import CSV: write 
import DataFrames: DataFrame
import HTTP: Request
import HTTP.Exceptions: StatusError
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./deterministic.jl"); import .Deterministic: forecast

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
    # TODO(five): Make conversions more visible (MOVE TO TOP OF FILE?)
    conversion_rules = Dict{Symbol, Function}(
        :petri => (val)->parse_json_acset(LabelledPetriNet, val),
        :tspan => (val)->Tuple{Float64, Float64}(val),
        :params => (val)->Dict{String, Float64}(val),
        :initials => (val)->Dict{String, Float64}(val),
    )
    function coerce!(key) # Is there a more idiomatic way of doing this
        if haskey(args, key)
            args[key] = conversion_rules[key](args[key])
        end
    end
    coerce!.(keys(conversion_rules))
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
    # TODO(five): Support more return types other than CSV i.e. write more methods
    function prepare_output(dataframe::DataFrame)
        io = IOBuffer()
        # TODO(five): Write to remote server
        write(io, dataframe)
        String(take!(io))
    end
    valid_funcs = Dict("forecast"=>forecast)
    if !haskey(valid_funcs, name)
        return StatusError(404, "GET", "GET", "Function not found")
    end
    prog = prepare_output ∘ valid_funcs[name]
    args = get_args(req)
    start_run!(prog, args)
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
    @post "/runs/deterministic/{name}" make_deterministic_run
    @get  "/runs/{id}/status" fill_job((job)->job.state)
    @get  "/runs/{id}/result" fill_job(retrieve_results)
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
