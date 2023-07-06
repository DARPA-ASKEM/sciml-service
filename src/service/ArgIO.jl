"""
Provide external awareness / service-related side-effects to SciML operations
"""
module ArgIO

import Symbolics
import DataFrames: rename!, transform!, DataFrame, ByRow
import CSV
import HTTP: Request
import JSON3 as JSON

include("../Settings.jl"); import .Settings: settings
include("../contracts/Failures.jl"); import .Failures: Failure
include("./AssetManager.jl"); import .AssetManager: fetch_dataset, fetch_model, update_simulation, upload, register_config

export prepare_input, prepare_output


"""
Transform requests into arguments to be used by operation    

Optionally, IDs are hydrated with the corresponding entity from TDS.
"""
function prepare_input(args; context...)
    if settings["ENABLE_TDS"]
        update_simulation(context[:job_id], Dict([:status=>"running", :start_time => time()]))
    end
    if in(:timespan, keys(args))
        args[:timespan] = (args[:timespan]["start"], args[:timespan]["end"])
    end
    if in(:model_config_id, keys(args))
        args[:model] = fetch_model(args[:model_config_id])
    end
    if in(:dataset, keys(args)) && !isa(args[:dataset], String)
        args[:dataset] = fetch_dataset(args[:dataset]["id"], args[:dataset]["filename"], get(args[:dataset], "mappings", Dict()))
    end
    if in(:model_config_ids, keys(args))
        args[:models] = fetch_model.(map(string, args[:model_ids]))
    end
    if !in(:timespan, keys(args))
        args[:timespan] = nothing
    end
    if in(:extra, keys(args))
        for (key, value) in Dict(args[:extra]) 
            args[Symbol(key)] = value
        end
    end
    args
end

"""
Generate a `prepare_input` function that is already contextualized    
"""
function prepare_input(context)
    function contextualized_prepare_input(args)
        prepare_input(args; context...)
    end
end

"""
Normalize the header of the resulting dataframe and return a CSV

Optionally, the CSV is saved to TDS instead an the coreresponding ID is returned.    
"""
function prepare_output(dataframe::DataFrame; name="0", context...)
    stripped_names = names(dataframe) .=> (r -> replace(r, "(t)"=>"")).(names(dataframe))
    rename!(dataframe, stripped_names)
    if !settings["ENABLE_TDS"]
        io = IOBuffer()
        # TODO(five): Write to remote server
        CSV.write(io, dataframe)
        return String(take!(io))
    else
        return upload(dataframe, context[:job_id]; name=name)
    end
end

"""
Coerces NaN values to nothing for each parameter   
"""
function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}}; name="0", context...)
    nan_to_nothing(value) = isnan(value) ? nothing : value
    fixed_params = Dict{String, Float64}(string(key) => nan_to_nothing(value) for (key, value) in params)
    if settings["ENABLE_TDS"]
        model_config_id = register_config(fixed_params, context[:raw_args][:model_config_id], context[:raw_args][:dataset])
        payload = Dict("model_config_id" => model_config_id, "parameters" => fixed_params)        
        return upload(payload, context[:job_id]; name=name)
    end
end

"""
Record failure of job
"""
function prepare_output(failure; context...)
    if settings["ENABLE_TDS"]
        update_simulation(context[:job_id], Dict([:status => "failed", :completed_time => time(), :reason => failure.reason]))
    end
    failure
end

"""
Saves all subobjects
"""
function prepare_output(results::Dict{String}; context...)
    if settings["ENABLE_TDS"]
        urls = String[]
        for (name, value) in results
            url = prepare_output(value; context..., name=name) 
            append!(urls, [url])
        end
        update_simulation(context[:job_id], Dict([:status => "complete", :result_files => urls, :completed_time => time()]))
    end
end

"""
Generate a `prepare_output` function that is already contextualized    
"""
function prepare_output(context)
    function contextualized_prepare_output(arg)
        prepare_output(arg; context...)
    end
end


end