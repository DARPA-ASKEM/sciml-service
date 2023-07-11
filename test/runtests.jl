using Test
using DataFrames
using HTTP
using JSON3
using Oxygen
using SciMLBase: solve

# Required to run on machine without TDS/RabbitMQ
ENV["SIMSERVICE_ENABLE_TDS"] = "false"
ENV["SIMSERVICE_RABBITMQ_ENABLED"] = "false"

using SimulationService

#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin
    @testset "simulate" begin
        url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        obj = SimulationService.get_json(url)
        sys = SimulationService.ode_system_from_amr(obj)
        op = SimulationService.Simulate(sys, (0.0, 100.0))
        df = solve(op)
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 100.0)
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
    host = "127.0.0.1"
    port = 8080
    url = "http://$host:$port"

    server = start!(; host, port, async=true)

    ready = false
    while !ready
        try
            res = HTTP.get(url)
            ready = true
        catch
            sleep(1)
        end
    end

    @testset "/" begin
        res = HTTP.get(url)
        @test res.status == 200
        @test JSON3.read(res.body).status == "ok"
    end

    @testset "/operations/simulate" begin
        @test true # TODO
    end

    @testset "/operations/calibrate" begin
        @test true # TODO
    end

    @testset "/operations/ensemble" begin
        @test true # TODO
    end

    stop!()
end
