module Queuing

import Logging: AbstractLogger, LogLevel
import Logging
import AMQPClient: amqps_configure, basic_publish, channel, connection, Message, AMQPS_DEFAULT_PORT, UNUSED_CHANNEL
import JSON3 as JSON

include("./Settings.jl"); import .Settings: settings

function get_channel()
    conn = connection(; 
        virtualhost="/", 
        host="localhost", 
        port=settings["RABBITMQ_PORT"], 
        auth_params=Dict{String, Any}("MECHANISM"=>"AMQPLAIN", "LOGIN"=>settings["RABBITMQ_LOGIN"], "PASSWORD"=>settings["RABBITMQ_PASSWORD"]), 
        #amqps=amqps_configure()
    )
    channel(conn, UNUSED_CHANNEL, true)
end

default_chan = get_channel()

function publish_to_rabbitmq(content)
    json = convert(Vector{UInt8}, codeunits(JSON.write(content)))
    message = Message(json, content_type="application/json")
    # TODO(five): Regen channel
    basic_publish(default_chan, message; exchange="", routing_key=settings["RABBITMQ_ROUTE"])
end

struct MQLogger <: AbstractLogger
    publish_hook::Function
end

MQLogger() = MQLogger(publish_to_rabbitmq)

Logging.shouldlog(::MQLogger, args...; kwargs...) = true
Logging.min_enabled_level(::MQLogger) = LogLevel(0)
Logging.handle_message(logger::MQLogger, level, message, args...; kwargs...) = logger.publish_hook(message)
Logging.catch_exceptions(::MQLogger) = true

end # module Queuing
