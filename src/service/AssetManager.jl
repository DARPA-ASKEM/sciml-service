"""
Asset fetching from TDS
"""
module AssetManager

import DataFrames: DataFrame
import CSV, Downloads, HTTP
import OpenAPI.Clients: Client
import JSON3 as JSON
import AWS: @service
@service S3

import .Settings: settings

export fetch_dataset, fetch_model, upload

"""
Return model JSON as string from TDS by ID
"""
function fetch_model(model_id::Int64)
    response = HTTP.get("$(settings["TDS_URL"])/models/$model_id", ["Content-Type" => "application/json"])
    body = response.body |> JSON.read ∘ String
    body.content
end

"""
Return csv from TDS by ID
"""
function fetch_dataset(dataset_id::Int64)
    url = "$(settings["TDS_URL"])/datasets/$dataset_id/files"
    io = IOBuffer()
    Downloads.download(url, io)
    seekstart(io)
    CSV.read(io, DataFrame)
end

"""
Upload a CSV to TDS
"""
function upload(output::DataFrame)
    # TODO(five): Stream so there isn't duplication
    io = IOBuffer()
    CSV.write(io, output)
    seekstart(io)
    
    params = Dict(
        "Body" => io
    )
    
    handle = "subject"
    
    S3.put_object("idk", handle, params)
    
end

end # module AssetManager
