"""
Provide external awareness / service-related side-effects to SciML operations
"""
module ArgIO

import Symbolics
import DataFrames: rename!, transform!, DataFrame, ByRow
import CSV
import HTTP: Request

include("../Settings.jl"); import .Settings: settings
include("./AssetManager.jl"); import .AssetManager: fetch_dataset, fetch_model, upload

export prepare_input, prepare_output

"""
Change arbitrary timespan to the range 0, 1, ...n
"""
function normalize_tspan(tstart, tend, stepsize)
    diff = tend - tstart
    if diff % stepsize != 0
        throw("Steps exceed the end of timespan!")
    end
    (0, floor(diff/stepsize))
end

"""
Transform naive step into epoch
"""
function get_step(tstart, stepsize, step)::Int
    stepsize*step + tstart
end

"""
Transform requests into arguments to be used by operation    

Optionally, IDs are hydrated with the corresponding entity from TDS.
"""
function prepare_input(args; context...)
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
    if in(:timespan, keys(args)) && !isa(args[:timespan], AbstractArray)
        span = args[:timespan]
        args[:timespan] = normalize_tspan(span["start_epoch"],span["end_epoch"],span["tstep_seconds"])
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
function prepare_output(dataframe::DataFrame; context...)
    stripped_names = names(dataframe) .=> (r -> replace(r, "(t)"=>"")).(names(dataframe))
    rename!(dataframe, stripped_names)
    if !isa(context[:raw_args], AbstractArray)
        scale_step(step) = get_step(context[:raw_args][:timespan]["start_epoch"], context[:raw_args][:timespan]["tstep_seconds"], step)
        dataframe.timestamp = map(scale_step, dataframe.timestamp)
    end
    if in("upload", keys(context[:raw_args][:extra])) && !context[:raw_args][:extra]["upload"]
        io = IOBuffer()
        # TODO(five): Write to remote server
        CSV.write(io, dataframe)
        return String(take!(io))
    else
        return upload(dataframe, context[:job_id])
    end
end

"""
Coerces NaN values to nothing for each parameter   
"""
function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}}; context...)
    nan_to_nothing(value) = isnan(value) ? nothing : value
    Dict(key => nan_to_nothing(value) for (key, value) in params)
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