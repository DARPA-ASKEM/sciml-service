@compile_workload begin
    SimulationService.amr_get(JSON3.read(joinpath(@__DIR__, "..", "examples", "calibrate_example1", "BIOMD0000000955_askenet.json")), ODESystem)
end
