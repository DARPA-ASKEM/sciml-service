"""
Asset fetching from TDS
"""
module AssetManager

import DataFrames: DataFrame
import CSV, Downloads, HTTP
import OpenAPI.Clients: Client
import JSON3 as JSON
import UUIDs: UUID
using AWS
include("./MinIO.jl"); using .MinIO
include("../Settings.jl"); import .Settings: settings
@service S3

export fetch_dataset, fetch_model, upload

"""
Return model JSON as string from TDS by ID
"""
function fetch_model(model_id::String)
    response = HTTP.get("$(settings["TDS_URL"])/models/$model_id", ["Content-Type" => "application/json"])
    body = response.body |> JSON.read ∘ String
    body.content
end

"""
Return csv from TDS by ID
"""
function fetch_dataset(dataset_id::String)
    url = "$(settings["TDS_URL"])/datasets/$dataset_id/file"
    io = IOBuffer()
    Downloads.download(url, io)
    seekstart(io)
    CSV.read(io, DataFrame)
end

"""
Report the job as completed    
"""
function report_completed(job_id::Int64)
    uuid = UUID(job_id)
    response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"])
    body = response.body |> JSON.read ∘ String
    body[:status] = "complete"
    HTTP.put("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"], body=body)
end

"""
Upload a CSV to S3/MinIO
"""
function upload(output::DataFrame, job_id)
    # TODO(five): Stream so there isn't duplication
    CONTENT_TYPE = "text/csv"
    io = IOBuffer()
    CSV.write(io, output)
    seekstart(io)
    params = Dict(
        "body" => take!(io),
        "content-type" => CONTENT_TYPE
    )
    
    handle = "$job_id.csv"

    # TODO(five): Call once
    AWS.global_aws_config(config)

    S3.put_object(settings["BUCKET"], handle, params)
    
    return Dict("data_path" => handle)
end

end # module AssetManager
