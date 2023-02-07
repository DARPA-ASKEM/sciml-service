# Executor
Executor provides an interface and job scheduler for [EasyModelAnalysis.jl](https://github.com/SciML/EasyModelAnalysis.jl). 

## Usage
To get started first run 
```
cp config.env.sample config.env
```
Make any necessary configuration changes inside of config.env

Finally, start the services with
```
docker compose -f docker/docker-compose.yml up
```

## Developing

The simplest way to install poetry (the prerequisite package manager) is `pip install poetry`.

To initialize a development environment, run the following commands:
```
poetry install;
poetry run pre-commit install
```

Whenever dependencies are added, they should be associated with a 
*dependency group* (using `poetry add --group group_name pkg_name`.
There are four dependency groups:
1. `lib` - Dependencies used by `lib`, the shared local library for `workflow` and `api`. Exclusively used in the `lib` directory.
1. `api` - REST-related dependencies for the API. Exclusively used in the `api` directory.
1. `workflow` - Prefect related dependencies. Exclusively used in the `workflow` directory.
1. `dev` - Development related dependencies such as linting, testing, pre-committing, etc.

If more than one of shares a dependency, the dependency can be added for the entire project.
