# Architecture (Not current with re-write)

The Simulation Service (soon to be renamed SciML Service) is a REST API that wraps
specific SciML tasks. The service should match the spec [here](https://github.com/DARPA-ASKEM/simulation-api-spec)
since PyCIEMSS Service and SciML Service ideally are hot swappable.

The API creates a job using the JobSchedulers.jl library and updates the Terarium Data Service (TDS) with the status
of the job throughout its execution. Once the job completes, the results are written to S3. With most of the output artifacts, we do little postprocessing
after completing the SciML portion.

## Layout

Source is split into 5 major components:
- `SimulationService.jl`: Contains the start and stop functions for the service
- `Settings.jl`: Enumerates the environment variables used by the project
- `service`: Job scheduling, pre/post-processing, endpoints, etc. Handled by TA4.
- `contracts`: Location where TA3 and TA4 agree on an interface between the SciML Operations and the rest of the service.
  - `Available.jl`: The operations available to the API are here. Generally, the operations just wrap around by the exposed SciML
                    operations.
- `operations`: JuliaHub primarily focuses here.
