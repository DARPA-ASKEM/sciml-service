using Test
using DataFrames
using EasyConfig
using HTTP
using JSON3
using Oxygen
using SciMLBase: solve
using ModelingToolkit

using SimulationService

SimulationService.SIMSERVICE_ENABLE_TDS = false

#-----------------------------------------------------------------------------# AMR parsing
@testset "AMR parsing" begin
    file = joinpath(@__DIR__, "..", "examples", "BIOMD0000000955_askenet.json")
    amr = JSON3.read(read(file), Config)
    sys = SimulationService.ode_system_from_amr(amr)
    @test string.(states(sys)) == ["Susceptible(t)", "Diagnosed(t)", "Infected(t)", "Ailing(t)", "Recognized(t)", "Healed(t)", "Threatened(t)", "Extinct(t)"]
    @test string.(parameters(sys)) == ["beta", "gamma", "delta", "alpha", "epsilon", "zeta", "lambda", "eta", "rho", "theta", "kappa", "mu", "nu", "xi", "tau", "sigma"]
    @test map(x->string(x.lhs), observed(sys)) == ["Cases(t)", "Hospitalizations(t)", "Deaths(t)"]
end

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
@testset "Server Routes" begin
    SimulationService.SIMSERVICE_ENABLE_TDS = false
    start!()

    url = SimulationService.server_url[]

    sleep(1) # wait for server to start

    @testset "/" begin
        res = HTTP.get(url)
        @test res.status == 200
        @test JSON3.read(res.body).status == "ok"
    end

    @testset "/simulate" begin
        file = joinpath(@__DIR__, "..", "examples", "BIOMD0000000955_askenet.json")
        amr = JSON3.read(read(file), Config)
        json = Config(test_amr = amr, timespan=Dict("start" => 0, "end" => 90))
        body = JSON3.write(json)
        res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body=body)
        @test res.status == 201

        done_or_failed = false
        job_id = JSON3.read(res.body).simulation_id
        while !done_or_failed
            status = JSON3.read(HTTP.get("$url/status/$job_id").body)
            if status.status == "complete"
                @test true
                done_or_failed = true
            elseif status.status == "error"
                @test false
                done_or_failed = true
            end
            sleep(1)
        end
    end

    @testset "/calibrate" begin
        @test true # TODO
    end

    @testset "/ensemble" begin
        @test true # TODO
    end

    stop!()
end
