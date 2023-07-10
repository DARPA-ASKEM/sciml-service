using Test
using Downloads: download
using HTTP
using JSON3
using SimulationService
# using SafeTestsets


#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin
    @testset "simulate" begin
        url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        json_string = read(download(url), String)
        model = SimulationService.Service.Execution.Interface.Available.ProblemInputs.coerce_model(json_string)
        f = SimulationService.Service.Execution.Interface.Available.get_operation(:simulate)
        f(; model, context=nothing)
    end
    @testset "calibrate" begin
        # TODO
    end
    @testset "ensemble" begin
        # TODO
    end
end


# @safetestset "sciml" begin include("sciml.jl") end
