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
>> julia --project --threads=auto  # Multithreading required for server
```

```julia
using SimulationService, HTTP, JSON3, EasyConfig

# Start the server/job scheduler without Terrarium Data Service
SimulationService.SIMSERVICE_ENABLE_TDS = false
start!()

url = SimulationService.server_url[]  # server url
@info JSON3.read(HTTP.get(url).body) # Is server running? (status == "ok")

# JSON in ASKEM Model Representation
amr = JSON3.read(read("./examples/BIOMD0000000955_askenet.json"), Config)

# You can directly provide AMR JSON with the `test_amr` key
# (Note: this does not look like a request that would be seen in production)
json = Config(test_amr = amr, timespan=(0, 90))

body = JSON3.write(json)

# Kick off the simulation job
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body=body)

# Get the `job_id` so we can query the job status and get results
job_id = JSON3.read(res.body).simulation_id

# Re-run this until `status_obj.status == "done"`
status = JSON3.read(HTTP.get("$url/jobs/status/$job_id").body)

# Get the result of the simulation job
result = JSON3.read(HTTP.get("$url/jobs/results/$job_id").body)

# close down server and scheduler
stop!()
````

To check available endpoints, try checking [localhost:8080/docs](localhost:8080/docs)
