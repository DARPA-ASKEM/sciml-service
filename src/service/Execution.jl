"""
Manage jobs
"""
module Execution

import HTTP: Request, Response
import JSON3 as JSON
import JobSchedulers: submit!, job_query, result, generate_id, Job, JobSchedulers

include("../contracts/Interface.jl"); import .Interface: get_operation, use_operation, Context
include("./ArgIO.jl"); import .ArgIO: prepare_input, prepare_output
include("./Queuing.jl"); import .Queuing: publish_to_rabbitmq
include("../Settings.jl"); import .Settings: settings

export make_deterministic_run, retrieve_job

SCHEDULER_TO_API_STATUS_MAP = Dict(
    JobSchedulers.QUEUING => :queued,
    JobSchedulers.RUNNING => :running,
    JobSchedulers.DONE => :complete,
    JobSchedulers.FAILED => :error,
    JobSchedulers.CANCELLED => :error,
)

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
    if isnothing(get_operation(operation))
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Operation not found"
        )
    end

    publish_hook = settings["SHOULD_LOG"] ? publish_to_rabbitmq : (_...) -> nothing

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
        return Dict("status" => SCHEDULER_TO_API_STATUS_MAP[job.state])
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

end # module Execution
