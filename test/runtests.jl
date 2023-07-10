using Test
using Downloads: download
using HTTP
using JSON3
using SimulationService


#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin
    @testset "simulate" begin
        url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        json_string = read(download(url), String)
        model = SimulationService._get(Val(:model), json_string)
        f(; model, context=nothing)
    end

    @testset "calibrate" begin
        # TODO
    end

    @testset "ensemble" begin
        # TODO
    end
end

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
        @test JSON3.read(res.body).status == "ok"
    end
end
