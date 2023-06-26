using Test: @test
using Downloads: download
using HTTP
using JSON3
using SimulationService
# using SafeTestsets


#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin

    for (url, op) in [
        ("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json", :simulate),
        ("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/regnet/examples/lotka_volterra.json", :calibrate),
    ]
        @testset "Operations.$op" begin
            json_string = read(download(url), String)

            f = SimulationService.Service.Execution.Interface.Available.get_operation(op)

            model = SimulationService.Service.Execution.Interface.Available.ProblemInputs.coerce_model(json_string)

            f(; model, context=nothing)
        end
    end
end


# @safetestset "sciml" begin include("sciml.jl") end
