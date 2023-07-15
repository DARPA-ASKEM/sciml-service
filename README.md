# SimulationService.jl

SimulationService runs a REST API for running jobs in the [ASKEM Model Representation](https://github.com/DARPA-ASKEM/Model-Representations).

The SimulationService follows the OpenAPI spec [here](https://github.com/DARPA-ASKEM/simulation-api-spec/blob/main/openapi.yaml)

See example payloads in the `./examples` directory or at [https://github.com/DARPA-ASKEM/simulation-api-spec](https://github.com/DARPA-ASKEM/simulation-api-spec).

## Development Environment

```julia
using Revise  # auto-update the server with your changes
using SimulationService
SimulationService.ENABLE_TDS = false  # opt out of Terrarium Data Service

start!()  # run server

# make code changes that you want to test...

start!()  # Replaces the running server with your changes
```

## Run Server via Docker

```
docker compose --file docker/docker-compose.yml up --build
```

## Example Request with Local Server in Julia

```julia
using SimulationService, HTTP, JSON3, EasyConfig

# Start the server/job scheduler without Terrarium Data Service
SimulationService.ENABLE_TDS = false
start!()

url = SimulationService.server_url[]  # server url
@info JSON3.read(HTTP.get(url).body) # Is server running? (status == "ok")

# JSON in ASKEM Model Representation
model = JSON3.read(read("./examples/BIOMD0000000955_askenet.json"), Config)

# You can directly provide AMR JSON with the `test_amr` key
# (Note: this does not entirely look like a request that would be seen in production)
json = @config(model = model, timespan.start=0, timespan.end=90, engine="sciml")

body = JSON3.write(json)

# Kick off the simulation job
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body=body)

# Get the `id` so we can query the job status and get results
id = JSON3.read(res.body).simulation_id

# Re-run this until `status_obj.status == "done"`
status = JSON3.read(HTTP.get("$url/status/$id").body)

# close down server and scheduler
stop!()
```

## Incoming Requests

The OpenAPI spec [here](https://raw.githubusercontent.com/DARPA-ASKEM/simulation-api-spec/main/openapi.yaml) is the source of truth.  See the JSON files in `./examples` that begin with `request-...`.

Here's a summary of what the JSON should like in a request:

1. Every request should contain `"engine": "sciml"`
2. Endpoint-specific keys:
    - `/simulate`
        - Required: `model_config_id`, `timespan`
        - Optional: `extra`
    - `/calibrate`
        - Required: `model_config_id`, `dataset`
        - Optional: `extra`, `timespan`
    - `/ensemble`
        - Required: `model_config_ids`, `timespan`
        - Optional: `extra`

Where (in Julia-speak):

```julia
model_config_id::String
model_config_ids::Vector{String}
timespan::JSON3.Object  # keys (start::Number, end::Number)
extra::JSON3.Object # any keys possible
dataset::JSON3.Object  # keys (id::String, filename::String, mappings::Object(col_name => new_col_name))
```

### How Incoming Requests are Processed

An incoming `HTTP.Request` gets turned into a `SimulationService.OperationRequest` object that holds
all the necessary info for running/solving the model and returning results.


1. Request arrives
2. We process the keys into useful things for `OperationRequest`
    - `model_config_id(s)` --> Retrieve model(s) in AMR format from TDS (`model::Config` in `OperationRequest`).
    - `dataset` --> Retrieve dataset from TDS (`df::DataFrame` in `OperationRequest`).
3. We start the job via JobSchedulers.jl, which performs:
    - Update job status in TDS to "running".
    - Run/solve the model/simulation.
    - Upload results to S3.
    - Update job status in TDS to "complete".
4. Return a 201 response (above job runs async) with JSON that holds the `simulation_id` (client's term), which we call `id`.


## Architecture

The Simulation Service (soon to be renamed SciML Service) is a REST API that wraps
specific SciML tasks. The service should match the spec [here](https://github.com/DARPA-ASKEM/simulation-api-spec)
since PyCIEMSS Service and SciML Service ideally are hot swappable.

The API creates a job using the JobSchedulers.jl library and updates the Terarium Data Service (TDS) with the status
of the job throughout its execution. Once the job completes, the results are written to S3. With most of the output artifacts, we do little postprocessing
after completing the SciML portion.
