module Settings

settings = Dict{String, Any}()

macro setting(name::Symbol, type::Union{DataType, Type}, default_value::Any)
    fixed_default = isa(default_value, Symbol) ? eval(default_value) : default_value
    if !isnothing(fixed_default)
        @assert typeof(fixed_default) == type
    end

    env_key = String(name)

    function grab_env() 
        try 
            return type(ENV[env_key])
        catch e
            if isa(e, KeyError) && !isnothing(fixed_default)
                return fixed_default
            else
                throw(e)
            end
        end
    end
    :(settings[$env_key] = ($grab_env)())
end

macro setting(name::Symbol, type::Symbol, default_value::Any)
    :(@setting(name, eval(type), fixed_default))
end

macro setting(name::Symbol, default_value::Any)
    type = typeof(default_value)
    :(@setting($name, $type, $default_value))
end

macro setting(name::Symbol)
    :(@setting($name, String, nothing))
end

@setting SHOULD_LOG "no" # TODO(five): Make boolean
@setting RABBITMQ_LOGIN "guest"
@setting RABBITMQ_PASSWORD "guest"
@setting RABBITMQ_ROUTE "terarium"
@setting RABBITMQ_PORT 5672
@setting TDS_URL "localhost:8001"

end # module Settings
