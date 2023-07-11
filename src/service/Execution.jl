"""
Manage jobs
"""
module Execution

import HTTP: Request, Response
import JSON3 as JSON
import Oxygen: json
import JobSchedulers: submit!, job_query, result, generate_id, Job, JobSchedulers
import UUIDs: UUID

include("../contracts/Interface.jl"); import .Interface: available_operations, use_operation, Context
include("./AssetManager.jl"); import .AssetManager: update_simulation
include("./ArgIO.jl"); import .ArgIO: prepare_input, prepare_output
include("./Queuing.jl"); import .Queuing: publish_to_rabbitmq
include("../Settings.jl"); import .Settings: settings

export make_deterministic_run, retrieve_job

SCHEDULER_TO_API_STATUS_MAP = Dict(
    JobSchedulers.QUEUING => :queued,
    JobSchedulers.RUNNING => :running,
    JobSchedulers.DONE => :complete,
    JobSchedulers.FAILED => :error,
    JobSchedulers.CANCELLED => :cancelled,
)

"""
Generate the task to run with the correct context    
"""
function contextualize_prog(context)
    function prog(args)
        try
            (prepare_output(context) ∘ use_operation(context) ∘ prepare_input(context))(args)
        catch exception
            if settings["ENABLE_TDS"]
                update_simulation(context.job_id, Dict([:status=>"error"]))
            end
            rethrow(exception)
        end
    end
end

# Coerce request object to dict
make_deterministic_run(req::Request, operation::String) = make_deterministic_run(json(req, Dict{Symbol, Any}), operation)

"""
Schedule a sim run given an operation
"""
function make_deterministic_run(args, operation::String)
    # TODO(five): Spawn remote workers and run jobs on them
    if !in(operation, keys(available_operations))
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Operation not found"
        )
    end

    publish_hook = settings["RABBITMQ_ENABLED"] ? publish_to_rabbitmq : (_...) -> nothing

    context = Context(
        generate_id(),
        publish_hook,  
        Symbol(operation),
        args
    )
    prog = contextualize_prog(context)
    sim_run = Job(@task(prog(args)))
    sim_run.id = context.job_id
    submit!(sim_run)
    uuid = "sciml-" * string(UUID(sim_run.id))
    Response(
        201,
        ["Content-Type" => "application/json; charset=utf-8"],
        body=JSON.write("simulation_id" => uuid)
    )
end


"""
Get status of sim
"""
function retrieve_job(_, uuid::String, element::String)
    id = Int64(UUID(split(uuid, "sciml-")[2]).value)
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
