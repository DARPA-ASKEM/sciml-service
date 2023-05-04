"""
RabbitMQ Integration    
"""
module Queuing

import Logging: AbstractLogger, LogLevel
import Logging
import AMQPClient: amqps_configure, basic_publish, channel, connection, Message, AMQPS_DEFAULT_PORT, UNUSED_CHANNEL
import JSON3 as JSON

include("./Settings.jl"); import .Settings: settings

"""
Connect to channel    
"""
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

"""
Publish JSON to RabbitMQ    
"""
function publish_to_rabbitmq(content)
    chan = get_channel() # TODO(five): Don't recreate for each call
    json = convert(Vector{UInt8}, codeunits(JSON.write(content)))
    message = Message(json, content_type="application/json")
    # TODO(five): Regen channel
    basic_publish(chan, message; exchange="", routing_key=settings["RABBITMQ_ROUTE"])
end

"""
Logger that calls an arbitrary hook on a message    
"""
struct MQLogger <: AbstractLogger
    publish_hook::Function
end

"""
MQLogger preloaded with RabbitMQ publishing    
"""
MQLogger() = MQLogger(publish_to_rabbitmq)

Logging.shouldlog(::MQLogger, args...; kwargs...) = true
Logging.min_enabled_level(::MQLogger) = LogLevel(0)
Logging.handle_message(logger::MQLogger, level, message, args...; kwargs...) = logger.publish_hook(message)
Logging.catch_exceptions(::MQLogger) = true

end # module Queuing
