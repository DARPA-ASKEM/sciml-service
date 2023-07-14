using Test
using DataFrames
using Distributions
using EasyConfig
using HTTP
using JSON3
using Oxygen
using SciMLBase: solve
using ModelingToolkit
using CSV


using SimulationService
using SimulationService: DataServiceModel, OperationRequest, Simulate, Calibrate, Ensemble

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
end

#-----------------------------------------------------------------------------# AMR parsing
@testset "AMR parsing" begin
    file = here("examples", "BIOMD0000000955_askenet.json")
    amr = JSON3.read(read(file), Config)
    sys = SimulationService.amr_get(amr, ODESystem)
    @test string.(states(sys)) == ["Susceptible(t)", "Diagnosed(t)", "Infected(t)", "Ailing(t)", "Recognized(t)", "Healed(t)", "Threatened(t)", "Extinct(t)"]
    @test string.(parameters(sys)) == ["beta", "gamma", "delta", "alpha", "epsilon", "zeta", "lambda", "eta", "rho", "theta", "kappa", "mu", "nu", "xi", "tau", "sigma"]
    @test map(x->string(x.lhs), observed(sys)) == ["Cases(t)", "Hospitalizations(t)", "Deaths(t)"]

    priors = SimulationService.amr_get(amr, sys, Val(:priors))
    @test priors isa Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Uniform{Float64}}}
    @test string.(first.(priors)) == string.(parameters(sys))
    @test last.(priors) isa Vector{Uniform{Float64}}

    df = CSV.read(here("examples", "dataset.csv"), DataFrame)
    data = SimulationService.amr_get(df, sys, Val(:data))
    @test data isa Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Tuple{Vector{Int64}, Vector{Float64}}}}
    @test string.(first.(data)) == string.(states(sys))
    @test all(all.(map(first.(last.(data))) do x; x .== 0:89; end))
end

#-----------------------------------------------------------# DataServiceModel and OperationRequest
@testset "DataServiceModel and OperationRequest" begin
    m = DataServiceModel()
    @test m.engine == "sciml"
    @test m.id == "UNINITIALIZED_ID"

    o = OperationRequest(operation = :simulate)
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

@testset "Operations Direct" begin
    @testset "calibrate" begin
        file = here("examples", "BIOMD0000000955_askenet.json")
        amr = JSON3.read(read(file), Config)
        sys = SimulationService.amr_get(amr, ODESystem)
        priors = SimulationService.amr_get(amr, sys, Val(:priors))
        df = CSV.read(here("examples", "dataset.csv"), DataFrame)
        data = SimulationService.amr_get(df, sys, Val(:data))
        num_chains = 4
        num_iterations = 100
        calibrate_method = "bayesian"
        ode_method = nothing
        o = SimulationService.Calibrate(sys, (0.0, 89.0), priors, data, num_chains, num_iterations, calibrate_method, ode_method)

        
        dfsim, dfparam = SimulationService.solve(o; callback = nothing)

        statenames = [states(o.sys);getproperty.(observed(o.sys), :lhs)]
        @test names(dfsim) == vcat("timestamp",reduce(vcat,[string.("ensemble",i,"_", statenames) for i in 1:size(dfsim,2)÷length(statenames)]))
        @test names(dfparam) == string.(parameters(sys))
    end
end

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
        json_url = here("examples", "request-calibrate-no-integration.json")
        obj = JSON3.read(read(json_url), Config)
        
        amr_url = here("examples", "BIOMD0000000955_askenet.json")
        amr = JSON3.read(read(amr_url), Config)
        priors = SimulationService.amr_get(amr, sys, Val(:priors))
        df = CSV.read(here("examples", "dataset.csv"), DataFrame)

        sys = SimulationService.amr_get(obj, ODESystem)
        op = Simulate(sys, (0.0, 99.0))
        df = solve(op)
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 99.0)
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
