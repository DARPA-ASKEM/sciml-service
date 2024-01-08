#@compile_workload begin
#    SimulationService.amr_get(JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json").body).configuration, ODESystem)
#end
