"""
Provide external awareness / service-related side-effects to SciML operations
"""
module ArgIO

import Symbolics
import DataFrames: DataFrame, rename!
import CSV
import HTTP: Request
import Oxygen: serveparallel, serve, resetstate, json, setschema, @post, @get

include("../Settings.jl"); import .Settings: settings
include("./AssetManager.jl"); import .AssetManager: fetch_dataset, fetch_model, upload

export prepare_input, prepare_output, Context

Context = Union{Dict{Symbol, Any}, NamedTuple} # TODO(five): Make this type more general


"""
Transform requests into arguments to be used by operation    

Optionally, IDs are hydrated with the corresponding entity from TDS.
"""
function prepare_input(req::Request; context...)
    args = json(req, Dict{Symbol,Any})
    if settings["ENABLE_REMOTE_DATA_HANDLING"]
        if in(:model, keys(args))
            args[:model] = fetch_model(args[:model])   
        end
        if in(:dataset, keys(args)) 
            args[:dataset] = fetch_dataset(args[:dataset])   
        end
    end
    args
end

"""
Generate a `prepare_input` function that is already contextualized    
"""
function prepare_input(context::Context)
    function contextualized_prepare_input(req::Request)
        prepare_input(req; context...)
    end
end

"""
Normalize the header of the resulting dataframe and return a CSV

Optionally, the CSV is saved to TDS instead an the coreresponding ID is returned.    
"""
function prepare_output(dataframe::DataFrame; context...)
    stripped_names = names(dataframe) .=> (r -> replace(r, "(t)"=>"")).(names(dataframe))
    rename!(dataframe, stripped_names)
    rename!(dataframe, "timestamp" => "timestep")
    if !settings["ENABLE_REMOTE_DATA_HANDLING"]
        io = IOBuffer()
        # TODO(five): Write to remote server
        CSV.write(io, dataframe)
        return String(take!(io))
    else
        return upload(dataframe, context[:job_id])
    end
end

"""
Coerces NaN values to nothing for each parameter.    
"""
function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}}; context...)
    nan_to_nothing(value) = isnan(value) ? nothing : value
    Dict(key => nan_to_nothing(value) for (key, value) in params)
end

"""
Generate a `prepare_output` function that is already contextualized    
"""
function prepare_output(context::Context)
    function contextualized_prepare_output(arg)
        prepare_output(arg; context...)
    end
end


end