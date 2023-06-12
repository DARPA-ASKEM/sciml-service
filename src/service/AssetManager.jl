"""
Asset fetching from TDS
"""
module AssetManager

import DataFrames: DataFrame
import CSV, Downloads, HTTP
import OpenAPI.Clients: Client
import JSON3 as JSON
import UUIDs: UUID
include("../Settings.jl"); import .Settings: settings

export fetch_dataset, fetch_model, update_simulation, upload

"""
Generate UUID with prefix    
"""
function gen_uuid(job_id)
    "sciml-" * string(UUID(job_id))
end

"""
Return model JSON as string from TDS by ID
"""
function fetch_model(model_id::String)
    response = HTTP.get("$(settings["TDS_URL"])/model_configurations/$model_id", ["Content-Type" => "application/json"])
    body = response.body |> JSON.read ∘ String
    body.configuration
end

"""
Return csv from TDS by ID
"""
function fetch_dataset(dataset_id::String)
    # TODO(five): Select name dynamicially
    url = "$(settings["TDS_URL"])/datasets/$dataset_id/download-url?filename=dataset.csv"
    response = HTTP.get(url, ["Content-Type" => "application/json"])
    body = response.body |> JSON.read ∘ String
    io = IOBuffer()
    Downloads.download(body.url, io)
    seekstart(io)
    CSV.read(io, DataFrame)
end

"""
Report the job as completed    
"""
function update_simulation(job_id::Int64, updated_fields::Dict{Symbol})
    uuid = gen_uuid(job_id)
    response = nothing
    remaining_retries = 10 # TODO(five)??: Set this with environment variable
    while remaining_retries != 0 
        remaining_retries -= 1
        sleep(2)
        try
            response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"])
            break
        catch exception
            if isa(exception,HTTP.Exceptions.StatusError) && exception.status == 404
                response = nothing
            else
                throw(exception)
            end
        end
    end
    if isnothing(response)
            throw("Job cannot finish because it does not exist in TDS")
    end
    body = response.body |> Dict ∘ JSON.read ∘ String
    for field in updated_fields
        body[field.first] = field.second
    end
    HTTP.put("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"], body=JSON.write(body))
end

"""
Upload a CSV to S3/MinIO
"""
function upload(output::DataFrame, job_id, name="result")
    uuid = gen_uuid(job_id)
    response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid/upload-url?filename=$name.csv", ["Content-Type" => "application/json"])
    # TODO(five): Stream so there isn't duplication
    io = IOBuffer()
    CSV.write(io, output)
    seekstart(io)
    url = JSON.read(response.body)[:url]
    HTTP.put(url, ["Content-Type" => "application/json"], body = take!(io))
    update_simulation(job_id, Dict(:status => "complete", :result_files => [split(url, "?")[1]], :completed_time => time()))
    "uploaded"
end


"""
Upload a JSON to S3/MinIO
"""
function upload(output::Dict, job_id, name="result")
    uuid = gen_uuid(job_id)
    response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid/upload-url?filename=$name.json", ["Content-Type" => "application/json"])
    url = JSON.read(response.body)[:url]
    HTTP.put(url, ["Content-Type" => "application/json"], body = JSON.write(output))
    update_simulation(job_id, Dict(:status => "complete", :result_files => [split(url, "?")[1]], :completed_time => time()))
    "uploaded"
end

end # module AssetManager
