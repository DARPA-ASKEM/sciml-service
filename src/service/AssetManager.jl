"""
Asset fetching from TDS
"""
module AssetManager

import DataFrames: DataFrame
import CSV, Downloads, HTTP
import OpenAPI.Clients: Client
import JSON3 as JSON
import JobSchedulers: generate_id
import AWS: @service, global_aws_config, AbstractAWSConfig, AWS
@service S3

include("../Settings.jl")
import .Settings: settings

export fetch_dataset, fetch_model, upload

# TODO(five): Move connection to separate file
# TODO(five): Connections to AWS already happen by default... Make explicit?
struct MinioConfig <: AbstractAWSConfig
   endpoint::String
   region::String
   creds
end
AWS.region(config::MinioConfig) = config.region
AWS.credentials(config::MinioConfig) = config.creds
    
struct SimpleCredentials
    access_key_id::String
    secret_key::String
    token::String
end
AWS.check_credentials(c::SimpleCredentials) = c
    
function AWS.generate_service_url(aws::MinioConfig, service::String, resource::String)
    service == "s3" || throw(ArgumentError("Can only handle s3 requests to Minio"))
    return string(aws.endpoint, resource)
end
    
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
    url = "$(settings["TDS_URL"])/datasets/$dataset_id/file"
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
        "body" => take!(io)
    )
    
    handle = "$(generate_id()).csv" # TODO(five): Change this to the actual job ID once it's being passed in
    
    # TODO(five): Run this once rather than every invocation
    if length(settings["FILE_STORE"]) != 0
        global_aws_config(
            MinioConfig(
                settings["FILE_STORE"], 
                "aregion", 
                SimpleCredentials(settings["AWS_ACCESS_KEY_ID"], settings["AWS_SECRET_ACCESS_KEY"], "")
            )
        )
    end

    S3.put_object(settings["BUCKET"], handle, params)
    
    return handle
end

end # module AssetManager
