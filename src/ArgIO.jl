module ArgIO

import Symbolics
import DataFrames: DataFrame, rename!
import CSV
import HTTP: Request
import Oxygen: serveparallel, serve, resetstate, json, setschema, @post, @get

include("./Settings.jl"); import .Settings: settings
include("./AssetManager.jl"); import .AssetManager: fetch_dataset, fetch_model, upload

export prepare_input, prepare_output


function prepare_input(req::Request)
    args = json(req, Dict{Symbol,Any})
    if settings["ENABLE_TDS"]
        if in(:model, keys(args))
            args[:model] = fetch_model(args[:model])   
        end
        if in(:dataset, keys(args)) 
            args[:dataset] = fetch_dataset(args[:dataset])   
        end
    end
    args
end

function prepare_output(dataframe::DataFrame)
    stripped_names = names(dataframe) .=> (r -> replace(r, "(t)"=>"")).(names(dataframe))
    rename!(dataframe, stripped_names)
    rename!(dataframe, "timestamp" => "timestep")
    if !settings["ENABLE_TDS"]
        io = IOBuffer()
        # TODO(five): Write to remote server
        CSV.write(io, dataframe)
        return String(take!(io))
    else
        return upload(dataframe)
    end
end

function prepare_output(params::Vector{Pair{Symbolics.Num, Float64}})
    nan_to_nothing(value) = isnan(value) ? nothing : value
    Dict(key => nan_to_nothing(value) for (key, value) in params)
end

end