module Executor

import Oxygen: serveparallel, serve, resetstate, @post, @get
import HTTP.Exceptions: StatusError 
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

function submit()
    sim_run = Job(
        Task(()->"Hello World"),
        priority = 5
    )
    submit!(sim_run)
    sim_run.id
end

function fill_job(func)
    function job_injected_func(_, id::Int64)
        job = job_query(id)
        if isnothing(job)
            return StatusError(404, "GET", "GET", "Job does not exist")
        end
        func(job)
    end
end

function retrieve_results(job)
    if job.state != :done
        return StatusError(400, "GET", "GET", "Tried to access incomplete sim run")
    end
    result(job)
end

function register!()
    @post "/submit" submit
    @get "/status/{id}" fill_job((job)->job.state)
    @get "/result/{id}" fill_job(retrieve_results)
end

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
