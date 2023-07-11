# Simulation Service
Simulation Service provides an interface and job runner for [ASKEM models](https://github.com/DARPA-ASKEM/Model-Representations). 

See example payload at [./examples/request.json](./examples/request.json)

## Usage

With docker compose: 
```
docker compose --file docker/docker-compose.yml up --build
```

With Julia REPL assuming you want to run it standalone:

```
>> export ENABLE_TDS=false # Include if you would like to disable backend services
>> julia --project --threads 15 # We need multithreading
julia> using SimulationService, HTTP
julia> import JSON3 as JSON
julia> start!()
julia> model_json = String(read("./examples/BIOMD0000000955_askenet.json"))
julia> # Let's do a simulate
julia> operation = "simulate"
julia> operation_args = Dict(:model=> model_json, :timespan => Dict("start" => 0, "end" => 90)) # should match up to what's in Availble.jl
julia> simulation = SimulationService.make_deterministic_run(operation_args, operation)
julia> simulation_id = JSON.read(String(simulation.body)).simulation_id
julia> status = SimulationService.retrieve_job(nothing, simulation_id, "status") # rerun until complete
julia> result = SimulationService.retrieve_job(nothing, simulation_id, "result")
julia> # output of REST API and Scheduler
julia> stop!()
julia> # you may safely leave the repl or rerun `start!`
````

To check available endpoints, try checking [localhost:8080/docs](localhost:8080/docs)
