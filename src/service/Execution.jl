"""
Manage jobs
"""
module Execution

import HTTP: Request, Response
import JSON3 as JSON
import Logging: with_logger, AbstractLogger, BelowMinLevel, Logging
import Oxygen: json
import JobSchedulers: submit!, job_query, result, generate_id, Job, JobSchedulers
import UUIDs: UUID

include("../contracts/Interface.jl"); import .Interface: available_operations, use_operation, Context
include("./AssetManager.jl"); import .AssetManager: update_simulation, upload
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
Logger for tasks that writes to a buffer    
"""
struct TaskLogger <: AbstractLogger
    buffer::IOBuffer
    function TaskLogger()
        new(IOBuffer())
    end
end

function Logging.handle_message(logger::TaskLogger, level, message, _module, group, id, file, line; kwargs...)
    log = "[$level]($_module:$group @ $file:$line): $message\n"
    write(logger.buffer, log)
end
Logging.shouldlog(::TaskLogger, args...) = true
Logging.min_enabled_level(::TaskLogger) = BelowMinLevel 
Logging.catch_exceptions(::TaskLogger) = true
function Main.take!(logger::TaskLogger)
    seekstart(logger.buffer)
    take!(logger.buffer)
end


"""
Generate the task to run with the correct context    
"""
function contextualize_prog(context)
    function prog(args)
        logger = TaskLogger()
        with_logger(logger) do
            try
                (prepare_output(context) ∘ use_operation(context) ∘ prepare_input(context))(args)
            catch exception
                if settings["ENABLE_TDS"]
                    update_simulation(context.job_id, Dict([:status=>"error"]))
                end
                throw(exception)
            end
        end
        filename = upload(take!(logger), context.job_id; name= "logs")
        update_simulation(context.job_id, Dict{Symbol, Any}();append=Dict(:result_files=>filename))
    end
end

"""
Schedule a sim run given an operation
"""
function make_deterministic_run(req::Request, operation::String)
    # TODO(five): Spawn remote workers and run jobs on them
    if !in(operation, keys(available_operations))
        return Response(
            404,
            ["Content-Type" => "text/plain; charset=utf-8"],
            body="Operation not found"
        )
    end

    publish_hook = settings["RABBITMQ_ENABLED"] ? publish_to_rabbitmq : (_...) -> nothing

    args = json(req, Dict{Symbol,Any})
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
