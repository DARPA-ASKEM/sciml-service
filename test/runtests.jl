using Test
using DataFrames
using EasyConfig
using HTTP
using JSON3
using Oxygen
using SciMLBase: solve
using ModelingToolkit


using SimulationService
using SimulationService: DataServiceModel, OperationRequest, Simulate, Calibrate, Ensemble,
    @trycatch

SimulationService.ENABLE_TDS = false

here(x...) = joinpath(dirname(pathof(SimulationService)), "..", x...)

#-----------------------------------------------------------------------# JSON payloads for testing
# route => payload
simulate_payloads = JSON3.write.([
    @config(local_model_file=here("examples", "BIOMD0000000955_askenet.json"), timespan.start=0, timespan.end=100),
])

calibrate_payloads = JSON3.write.([])

ensemble_payloads = JSON3.write.([])

#-----------------------------------------------------------------------------# utils
@testset "utils" begin
    obj = SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/petrinet_schema.json")
    @test obj isa Config

    @test @trycatch(error()) == nothing
    @test @trycatch(true)
end

#-----------------------------------------------------------------------------# AMR parsing
@testset "AMR parsing" begin
    file = here("examples", "BIOMD0000000955_askenet.json")
    amr = JSON3.read(read(file), Config)
    sys = SimulationService.amr_get(amr, ODESystem)
    @test string.(states(sys)) == ["Susceptible(t)", "Diagnosed(t)", "Infected(t)", "Ailing(t)", "Recognized(t)", "Healed(t)", "Threatened(t)", "Extinct(t)"]
    @test string.(parameters(sys)) == ["beta", "gamma", "delta", "alpha", "epsilon", "zeta", "lambda", "eta", "rho", "theta", "kappa", "mu", "nu", "xi", "tau", "sigma"]
    @test map(x->string(x.lhs), observed(sys)) == ["Cases(t)", "Hospitalizations(t)", "Deaths(t)"]
end

#-----------------------------------------------------------# DataServiceModel and OperationRequest
@testset "DataServiceModel and OperationRequest" begin
    m = DataServiceModel()
    @test m.engine == :sciml
    @test m.id == "UNINITIALIZED_ID"

    o = OperationRequest()
    m2 = DataServiceModel(o)

    # OperationRequest constructor with dummy HTTP.Request
    req = HTTP.Request("POST", "", [], simulate_payloads[1])
    o = OperationRequest(req, "simulate")
    @test DataServiceModel(o).id == o.id

    # Test that `create` returns JSON with the required keys
    create_obj = JSON3.read(SimulationService.create(o), Config)
    @test all(haskey(create_obj, k) for k in [:id, :engine, :type, :execution_payload, :workflow_id])
end


#-----------------------------------------------------------------------------# Operations
@testset "Operations" begin
    @testset "simulate" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        obj = SimulationService.get_json(json_url)
        sys = SimulationService.amr_get(obj, ODESystem)
        op = Simulate(sys, (0.0, 99.0))
        df = solve(op)
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 99.0)
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

    sleep(3) # Give server a chance to start

    @testset "/" begin
        res = HTTP.get(url)
        @test res.status == 200
        @test JSON3.read(res.body).status == "ok"
    end

    @testset "/simulate" begin
        for body in simulate_payloads
            res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
            @test res.status == 201
            id = JSON3.read(res.body).simulation_id
            done_or_failed = false
            while !done_or_failed
                st = JSON3.read(HTTP.get("$url/status/$id").body).status
                st in ["queued", "complete", "running"] ? @test(true) : @test(false)
                done_or_failed = st in ["complete", "error"]
                sleep(1)
            end
            @test SimulationService.last_operation[].result isa DataFrame
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
