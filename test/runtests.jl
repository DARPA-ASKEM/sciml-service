using Test
using DataFrames
using EasyConfig
using HTTP
using JSON3
using Oxygen
using SciMLBase: solve
using ModelingToolkit

using SimulationService
using SimulationService: SimulationRecord, OperationRequest, Simulate, Calibrate, Ensemble

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

#-----------------------------------------------------------------------# JSON payloads for testing
# route => payload
simulate_payloads = JSON3.write.([
    @config(model_config_id="BIOMD0000000955_askenet.json", timespan.start=0, timespan.end=0),
])

calibrate_payloads = JSON3.write.([])

ensemble_payloads = JSON3.write.([])

#---------------------------------------------------------------# SimulationRecord/OperationRequest
@testset "SimulationRecord/OperationRequest structs" begin
    record = SimulationRecord()
    @test record.engine == :sciml
    @test isnothing(record.id)

    o = OperationRequest{Simulate}()
    @test o.operation_type == Simulate

    # OperationRequest constructor with dummy HTTP.Request
    req = HTTP.Request("POST", "", [], simulate_payloads[1])
    o = OperationRequest(req, "simulate")
    @test !isnothing(o.record.id)
end


#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin
    @testset "simulate" begin
        url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        obj = SimulationService.get_json(url)
        sys = SimulationService.ode_system_from_amr(obj)
        op = Simulate(sys, (0.0, 100.0))
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
    start!()

    url = SimulationService.server_url[]

    sleep(1) # wait for server to start

    @testset "/" begin
        res = HTTP.get(url)
        @test res.status == 200
        @test JSON3.read(res.body).status == "ok"
    end

    @testset "/simulate" begin
        for body in simulate_payloads
            res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
            @test res.status == 201
            job_id = JSON3.read(res.body).simulation_id
            done_or_failed = false
            while !done_or_failed
                st = JSON3.read(HTTP.get("$url/status/$job_id").body).status
                st in ["queued", "complete", "running"] ? @test(true) : @test(false)
                done_or_failed = st in ["complete", "error"]
                sleep(1)
            end
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
