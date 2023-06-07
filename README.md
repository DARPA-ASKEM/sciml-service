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
julia> using SimulationService
julia> start!()
julia> # output of REST API and Scheduler
julia> stop!()
julia> # you may safely leave the repl or rerun `start!`
````
