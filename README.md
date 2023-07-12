# Simulation Service
Simulation Service provides an interface and job runner for [ASKEM models](https://github.com/DARPA-ASKEM/Model-Representations).

See example payload at [./examples/request.json](./examples/request.json)

## Development Environment

```julia
using Revise  # auto-update the server with your changes
using SimulationService
SimulationService.SIMSERVICE_ENABLE_TDS = false  # opt out of Terrarium Data Service

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
SimulationService.SIMSERVICE_ENABLE_TDS = false
start!()

url = SimulationService.server_url[]  # server url
@info JSON3.read(HTTP.get(url).body) # Is server running? (status == "ok")

# JSON in ASKEM Model Representation
model = JSON3.read(read("./examples/BIOMD0000000955_askenet.json"), Config)

# You can directly provide AMR JSON with the `test_amr` key
# (Note: this does not look like a request that would be seen in production)
json = Config(model = model, timespan=(0, 90))

body = JSON3.write(json)

# Kick off the simulation job
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body=body)

# Get the `job_id` so we can query the job status and get results
job_id = JSON3.read(res.body).simulation_id

# Re-run this until `status_obj.status == "done"`
status = JSON3.read(HTTP.get("$url/jobs/status/$job_id").body)

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
        - Required: `model_config_id`: `dataset`
        - Optional: `extra`, `timespan`
    - `/ensemble`
        - Required: `model_config_ids`, `timespan`
        - Optional: `extra`
3. Additional keys (for testing/when TDS is disabled).
    - `csv`: A String containing the contents of a CSV file.
    - `local_csv`: The file path of a CSV file.
    - `model`: JSON object in the The ASKEM Model Representation (AMR) format.
