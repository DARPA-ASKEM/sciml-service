"""
Asset fetching from TDS
"""
module AssetManager

import DataFrames: rename!, DataFrame
import CSV, Downloads, HTTP
import OpenAPI.Clients: Client
import JSON3
import JSON
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
function fetch_model(model_config_id::String)
    response = HTTP.get("$(settings["TDS_URL"])/model_configurations/$model_config_id", ["Content-Type" => "application/json"])
    body = response.body |> JSON3.read ∘ String
    JSON3.write(body.configuration)
end

"""
Register a calibrated model config   
"""
function register_config(output::Dict, model_config_id::String, dataset) 
    response = HTTP.get("$(settings["TDS_URL"])/model_configurations/$model_config_id", ["Content-Type" => "application/json"])
    body = response.body |> JSON.parse ∘ String
    delete!(body, "id")
    body[:calibration] = dataset
    body[:calibrated] = true
    parameters = body[:configuration]["semantics"]["ode"]["parameters"]
    # updated_parameters = []
    for param in parameters
        # param_obj= copy(param) 
        # updated_param = Dict()
        # updated_param["id"] = param_obj[:id]
        # updated_param["distribution"] = get(param_obj, :distribution, nothing)
        param["value"] = output[string(param["id"])]

        # append!(updated_parameters, updated_param)
    end
    #body[:configuration]["semantics"]["ode"]["parameters"] = updated_parameters
    response = HTTP.post("$(settings["TDS_URL"])/model_configurations/$model_config_id", ["Content-Type" => "application/json"], body=JSON3.write(body))
    JSON3.read(response.body)[:id]
end

"""
Return csv from TDS by ID
"""
function fetch_dataset(dataset_id::String, filename::String, mappings::Dict=Dict())
    # TODO(five): Select name dynamicially
    url = "$(settings["TDS_URL"])/datasets/$dataset_id/download-url?filename=$filename"
    response = HTTP.get(url, ["Content-Type" => "application/json"])
    body = response.body |> JSON3.read ∘ String
    io = IOBuffer()
    Downloads.download(body.url, io)
    seekstart(io)
    dataframe = CSV.read(io, DataFrame)
    for (from, to) in mappings rename!(dataframe, Symbol(from)=>Symbol(to)) end
    dataframe
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
    body = response.body |> Dict ∘ JSON3.read ∘ String
    for field in updated_fields
        body[field.first] = field.second
    end
    HTTP.put("$(settings["TDS_URL"])/simulations/$uuid", ["Content-Type" => "application/json"], body=JSON3.write(body))
end

"""
Upload a CSV to S3/MinIO
"""
function upload(output::DataFrame, job_id; name="result")
    uuid = gen_uuid(job_id)
    response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid/upload-url?filename=$name.csv", ["Content-Type" => "application/json"])
    # TODO(five): Stream so there isn't duplication
    io = IOBuffer()
    CSV.write(io, output)
    seekstart(io)
    url = JSON3.read(response.body)[:url]
    HTTP.put(url, ["Content-Type" => "application/json"], body = take!(io))
    bare_url = split(url, "?")[1]
    bare_url
end


"""
Upload a JSON3 to S3/MinIO
"""
function upload(output::Dict, job_id; name="result")
    uuid = gen_uuid(job_id)
    response = HTTP.get("$(settings["TDS_URL"])/simulations/$uuid/upload-url?filename=$name.json", ["Content-Type" => "application/json"])
    url = JSON3.read(response.body)[:url]
    HTTP.put(url, ["Content-Type" => "application/json"], body = JSON3.write(output))
    bare_url = split(url, "?")[1]
    bare_url
end

end # module AssetManager
