using SimulationService
import ModelingToolkit: ODESystem
import JSON3
import HTTP
SimulationService.amr_get(JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json").body), ODESystem)
