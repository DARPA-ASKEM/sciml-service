"""
Project-wide environment settings    
"""
module Settings

"""
The current settings for the project    
"""
settings = Dict{String, Any}()

"""
Add a setting from the enviroment    
"""
macro setting(name::Symbol, type::Union{DataType, Type}, default_value::Any)
    fixed_default = isa(default_value, Symbol) ? eval(default_value) : default_value
    if !isnothing(fixed_default)
        @assert typeof(fixed_default) == type
    end

    env_key = String(name)

    function grab_env() 
        if in(env_key, keys(ENV))
            if type == String
                return ENV[env_key]
            else
                return parse(type, ENV[env_key])
            end
        else
            if !isnothing(fixed_default)
                ENV[env_key] = fixed_default
                return fixed_default
            else
                throw("Variable not in environment and no default provided!")
            end
        end
    end
    :(settings[$env_key] = ($grab_env)())
end

"""
Coerce `type` from `Symbol` to `Type`    
"""
macro setting(name::Symbol, type::Symbol, default_value::Any)
    :(@setting(name, eval(type), fixed_default))
end

"""
Set an option while inferring the type    
"""
macro setting(name::Symbol, default_value::Any)
    type = typeof(default_value)
    :(@setting($name, $type, $default_value))
end

"""
Set a string option    
"""
macro setting(name::Symbol)
    :(@setting($name, String, nothing))
end

@setting RABBITMQ_ENABLED false
@setting RABBITMQ_LOGIN "guest"
@setting RABBITMQ_PASSWORD "guest"
@setting RABBITMQ_ROUTE "terarium"
@setting RABBITMQ_PORT 5672
@setting ENABLE_TDS true
@setting TDS_URL "http://localhost:8001"

end # module Settings
