using Test
using Downloads: download
using HTTP
using JSON3
using SimulationService


#-----------------------------------------------------------------------------# test routes
@testset "Routes" begin
    host = "172.0.0.1"
    port = 8080
    url = "$host:$port"

    server = start!(; host, port, async=true)
    sleep(5)

    @testset "/" begin
        res = HTTP.get(url)
        @test res.status == 200
    end
end

# #-----------------------------------------------------------------------------# Operations
# @testset "Operations" begin
#     @testset "simulate" begin
#         url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
#         json_string = read(download(url), String)
#         model = SimulationService.Service.Execution.Interface.Available.ProblemInputs.coerce_model(json_string)
#         f = SimulationService.Service.Execution.Interface.Available.get_operation(:simulate)
#         f(; model, context=nothing)
#     end
#     @testset "calibrate" begin
#         # TODO
#     end
#     @testset "ensemble" begin
#         # TODO
#     end
# end


# @safetestset "sciml" begin include("sciml.jl") end
