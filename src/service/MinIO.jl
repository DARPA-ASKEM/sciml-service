"""
MinIO/S3 Handler   
"""
module MinIO
import AWS: AWS, AbstractAWSConfig

include("../Settings.jl")
import .Settings: settings

export MinioConfig, region, credentials, Credentials, check_credentials, generate_service_url, config

"""
MinIO/S3 Configuration
"""
struct MinioConfig <: AbstractAWSConfig
   endpoint::String
   region::String
   creds
end
AWS.region(config::MinioConfig) = config.region
AWS.credentials(config::MinioConfig) = config.creds
    
"""
Generic Credentials that work for MinIO and S3
"""
struct Credentials
    access_key_id::String
    secret_key::String
    token::String
end
AWS.check_credentials(c::Credentials) = c
    
function AWS.generate_service_url(aws::MinioConfig, service::String, resource::String)
    service == "s3" || throw(ArgumentError("Can only handle S3 requests"))
    SERVICE_HOST = "amazonaws.com"
    reg = AWS.region(aws)
    if length(settings["FILE_STORE"]) == 0
        return string(
            "https://", service, ".", isempty(reg) ? "" : "$reg.", SERVICE_HOST, resource
        )
    else
        return string(settings["FILE_STORE"], resource)
    end
end


config = MinioConfig(
    settings["FILE_STORE"], 
    AWS.DEFAULT_REGION, 
    Credentials(settings["AWS_ACCESS_KEY_ID"], settings["AWS_SECRET_ACCESS_KEY"], "")
)

end # module MinIO
