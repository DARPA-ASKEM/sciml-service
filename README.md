# Scheduler
Scheduler provides an interface and job scheduler for [EasyModelAnalysis.jl](https://github.com/SciML/EasyModelAnalysis.jl). 

See example payload at [./examples/request.json](./examples/request.json)

## Usage

In the Julia REPL:
```
using Scheduler; Scheduler.run!()
````

With docker compose: 
```
docker compose --file docker/docker-compose.yml up --build
```
