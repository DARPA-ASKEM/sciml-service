# Simulation Service
Simulation Service provides an interface and job runner for [ASKEM models](https://github.com/DARPA-ASKEM/Model-Representations).

See example payload at [./examples/request.json](./examples/request.json)

## Usage

With docker compose:
```
docker compose --file docker/docker-compose.yml up --build
```

With Julia REPL:

```
>> export ENABLE_TDS=false         # Disable backend Terrarium Data Service
>> julia --project --threads=auto  # Multithreading required for server
```

```julia
using SimulationService, HTTP, JSON3

# Start the server/job scheduler
start!()

# Get where server is running ("http:/127.0.0.1:8000" by default)
url = SimulationService.server_url[]

# JSON in ASKEM Model Representation
amr = JSON3.read(read("./examples/BIOMD0000000955_askenet.json"))

# Kick off the simulation job
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body=json)

# Get the `job_id` so we can query the job status and get results
job_id = JSON3.read(res.body).job_id

# Re-run this until `status_obj.status == "complete"`
status_obj = JSON3.read(HTTP.get("$url/status/$job_id").body)
while status_obj.status != "complete"
    status_obj = JSON3.read(HTTP.get("$url/status/$job_id").body)
end

# Get the result of the simulateion job
result = JSON3.read(HTTP.get("$url/results/$job_id").body)

# close down server and scheduler
stop!()

````

To check available endpoints, try checking [localhost:8080/docs](localhost:8080/docs)
