"""
Provide external awareness / service-related side-effects to SciML operations
"""
module ArgIO

import Symbolics
import DataFrames: rename!, transform!, DataFrame, ByRow
import CSV
import HTTP: Request

include("../Settings.jl"); import .Settings: settings
include("./AssetManager.jl"); import .AssetManager: fetch_dataset, fetch_model, update_simulation, upload

export prepare_input, prepare_output


"""
Transform requests into arguments to be used by operation    

Optionally, IDs are hydrated with the corresponding entity from TDS.
"""
function prepare_input(args; context...)
    if settings["ENABLE_TDS"]
        update_simulation(context[:job_id], Dict([:status=>"running", :start_time => time()]))
    end
    if in(:model_config_id, keys(args))
        args[:model] = fetch_model(string(args[:model_config_id]))
    end
    if in(:dataset_id, keys(args))
        args[:dataset] = fetch_dataset(string(args[:dataset_id]))
    end
    if in(:dataset_ids, keys(args))
        args[:datasets] = fetch_dataset.(map(string, args[:dataset_ids]))
    end
    if in(:model_config_ids, keys(args))
        args[:models] = fetch_model.(map(string, args[:model_ids]))
    end
    if !in(:timespan, keys(args))
        args[:timespan] = nothing
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
function prepare_output(dataframe::DataFrame; name="result", context...)
    stripped_names = names(dataframe) .=> (r -> replace(r, "(t)"=>"")).(names(dataframe))
    rename!(dataframe, stripped_names)
    if !settings["ENABLE_TDS"]
        io = IOBuffer()
        # TODO(five): Write to remote server
        CSV.write(io, dataframe)
        return String(take!(io))
    else
        return upload(dataframe, context[:job_id]; name="$(context[:raw_args][:operation])-results.csv")
    end
end

"""
Coerces NaN values to nothing for each parameter   
"""
function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}}; name="result", context...)
    nan_to_nothing(value) = isnan(value) ? nothing : value
    fixed_params = Dict(key => nan_to_nothing(value) for (key, value) in params)
    if settings["ENABLE_TDS"]
        return upload(fixed_params, context[:job_id]; name = name)
    end
end


"""
Coerces NaN values to nothing for each parameter   
"""
function prepare_output(results::AbstractArray; context...)
    if settings["ENABLE_TDS"]
        urls = []
        for result in results
            if !isnothing(result)
                append!(urls, [prepare_output(result; context..., name="$(length(urls))")])
            end
        end
        update_simulation(context[:job_id], Dict([:result_files => urls]))

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