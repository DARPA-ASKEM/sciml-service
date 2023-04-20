module Status

import AMQPClient: amqps_configure, basic_publish, channel, connection, Message, AMQPS_DEFAULT_PORT, UNUSED_CHANNEL
import JSON3 as JSON

include("./Settings.jl"); import .Settings: settings

function get_publish_json_hook()
    conn = connection(; 
        virtualhost="/", 
        host="localhost", 
        port=settings["RABBITMQ_PORT"], 
        auth_params=Dict{String, Any}("MECHANISM"=>"AMQPLAIN", "LOGIN"=>settings["RABBITMQ_LOGIN"], "PASSWORD"=>settings["RABBITMQ_PASSWORD"]), 
        #amqps=amqps_configure()
    )
    chan = channel(conn, UNUSED_CHANNEL, true)
    function hook(content)
        json = convert(Vector{UInt8}, codeunits(JSON.write(content)))

        message = Message(json, content_type="application/json")

        basic_publish(chan, message; exchange="", routing_key=settings["RABBITMQ_ROUTE"])
    end
end

end # module Status
