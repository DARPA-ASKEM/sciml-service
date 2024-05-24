using CSV
using DataFrames
using Dates
using Distributions
using HTTP
using JSON3
using ModelingToolkit
using Oxygen
using SciMLBase: solve
using Test
using SimulationService
using SimulationService: DataServiceModel, OperationRequest, Simulate, Calibrate, get_json

SimulationService.ENABLE_TDS[] = false
SimulationService.RABBITMQ_ENABLED[] = false
SimulationService.PORT[] = 8080 # avoid 8000 in case another server is running

# joinpath(root_of_repo, args...)
here(x...) = joinpath(dirname(pathof(SimulationService)), "..", x...)

#-----------------------------------------------------------------------# JSON payloads for testing
# route => payload


simulate_payloads = JSON3.write.([
    (
        configuration_file_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json",
        timespan = (; start=0, var"end"=100)
    ),
    (
        model_file_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIR_stockflow.json",
        timespan = (; start=0, var"end"=100)
    ),
    (
        model_file_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/LV_rabbits_wolves_regnet.json",
        timespan = (; start=0, var"end"=100)
    ),
    # 18-month Hackathon Epi Scenario 4:
    (
        model_file_url = "https://raw.githubusercontent.com/gyorilab/mira/main/notebooks/hackathon_2024.02/scenario4/scenario4_4spec_regnet.json",
        timespan = (; start=0, var"end"=30)
    ),
    (
        model_file_url = "https://raw.githubusercontent.com/gyorilab/mira/main/notebooks/hackathon_2024.02/scenario4/scenario4_6spec_regnet.json",
        timespan = (; start=0, var"end"=30)
    )
    ])

calibrate_payloads = JSON3.write.([
    let
        (; engine, timespan, extra) = SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/scenarios/sidarthe/sciml/calibrate.json")
        (;
            dataset_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/datasets/SIDARTHE_dataset.csv",
            configuration_file_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json",
            engine, timespan, extra
        )
    end
])


simulate_ensemble_payloads = JSON3.write.([
    (
        model_configs = map(1:2) do i
            (id="model_config_id_$i", weight = i / sum(1:2), solution_mappings = (any_generic = "I", name = "R", s = "S"))
        end,
        model_file_urls = ["https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRHD_base_model01_petrinet.json",
        "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRD_base_model01_petrinet.json"],
        timespan = (start = 0, var"end" = 40),
        engine = "sciml",
        extra = (; num_samples = 40)
    )
    #,
    #(
    #    model_configs = map(1:2) do i
    #        (id="model_config_id_$i", weight = i / sum(1:2), solution_mappings = (any_generic = "I", name = "R", s = "S"))
    #    end,
    #    model_file_urls = ["https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIR_stockflow.json",
    #    "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SIR_stockflow.json"],
    #    timespan = (start = 0, var"end" = 40),
    #    engine = "sciml",
    #    extra = (; num_samples = 40)
    #)

    ])

calibrate_ensemble_payloads = JSON3.write.([(
            model_configs = map(1:2) do i
                (id="model_config_id_$i", weight = 0.5, solution_mappings = (Ailing = "Ailing", Diagnosed = "Diagnosed", Extinct = "Extinct", Healed = "Healed", Infected = "Infected", Recognized = "Recognized", Susceptible = "Susceptible", Threatened = "Threatened"))
            end,
            configuration_file_urls = ["https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json",
            "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json"],
            timespan = (start = 0, var"end" = 89),
            engine = "sciml",
            dataset_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/datasets/SIDARTHE_dataset.csv",
            extra = (; num_samples = 40))]
        )

#-----------------------------------------------------------------------------# utils
@testset "utils" begin
    obj = SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/petrinet_schema.json")
    @test obj isa JSON3.Object
end

#-----------------------------------------------------------------------------# AMR parsing
@testset "Petrinet AMR parsing" begin
    amr = JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json").body)
    sys = SimulationService.amr_get(amr.configuration, ODESystem)
    @test string.(unknowns(sys)) == ["Susceptible(t)", "Diagnosed(t)", "Infected(t)", "Ailing(t)", "Recognized(t)", "Healed(t)", "Threatened(t)", "Extinct(t)"]
    @test string.(parameters(sys)) == ["beta", "gamma", "delta", "alpha", "epsilon", "zeta", "lambda", "eta", "rho", "theta", "kappa", "mu", "nu", "xi", "tau", "sigma"]
    @test map(x->string(x.lhs), observed(sys)) == ["Cases(t)", "Hospitalizations(t)", "Deaths(t)"]

    priors = SimulationService.amr_get(amr.configuration, sys, Val(:priors))
    @test priors isa Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Uniform{Float64}}}
    @test string.(first.(priors)) == string.(parameters(sys))
    @test last.(priors) isa Vector{Uniform{Float64}}

    df = CSV.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/datasets/SIDARTHE_dataset.csv").body,DataFrame)
    data = SimulationService.amr_get(df, sys, Val(:data))
    @test data isa Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Tuple{Vector{Int64}, Vector{Float64}}}}
    @test string.(first.(data)) == string.(unknowns(sys))
    @test all(all.(map(first.(last.(data))) do x; x .== 0:89; end))
end

@testset "Stock and Flow AMR parsing" begin
    amr = JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SIR_stockflow.json").body)
    sys = SimulationService.amr_get(amr, ODESystem)
    @test string.(unknowns(sys)) == ["S(t)", "I(t)", "R(t)"]
    @test string.(parameters(sys)) == ["p_cbeta","p_N", "p_tr"]

    priors = SimulationService.amr_get(amr, sys, Val(:priors))

    amr = JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIR_stockflow.json").body)
    sys = SimulationService.amr_get(amr, ODESystem)

    priors = SimulationService.amr_get(amr, sys, Val(:priors))
end

@testset "RegNet AMR parsing" begin
    amr = JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/LV_sheep_foxes_regnet.json").body)
    sys = SimulationService.amr_get(amr, ODESystem)
    @test string.(unknowns(sys)) == ["S(t)", "F(t)"]
    @test string.(parameters(sys)) == ["beta","delta", "alpha","gamma"]

    priors = SimulationService.amr_get(amr, sys, Val(:priors))
end
#-----------------------------------------------------------# DataServiceModel and OperationRequest
@testset "DataServiceModel and OperationRequest" begin
    @testset "DataServiceModel" begin
        example = """{
            "id": "sciml-dfca06dd-b044-436f-a744-0d0a30cc130f",
            "name": null,
            "description": null,
            "timestamp": "2023-07-16T21:00:47",
            "engine": "sciml",
            "type": "simulation",
            "status": "queued",
            "execution_payload": {
              "engine": "sciml",
              "model_config_id": "84d0b51d-7d4c-497f-98fa-a00e31c344db",
              "timespan": {
                "start": 1,
                "end": 100
              },
              "num_samples": null,
              "extra": {},
              "interventions": null
            },
            "start_time": null,
            "completed_time": null,
            "workflow_id": "dummy",
            "user_id": 0,
            "project_id": 0,
            "result_files": []
        }"""
        @test JSON3.read(example, DataServiceModel) isa DataServiceModel

    end


    m = DataServiceModel()
    @test m.engine == "sciml"
    @test m.id == ""

    o = OperationRequest(route = "simulate")
    m2 = DataServiceModel(o)

    # OperationRequest constructor with dummy HTTP.Request
    req = HTTP.Request("POST", "", [], simulate_payloads[1])
    o = OperationRequest(req, "simulate")
    @test DataServiceModel(o).id == o.id
    @test !isnothing(o.model)

    # Test that `create` returns JSON with the required keys
    create_obj = JSON3.read(SimulationService.create(o))
    @test all(haskey(create_obj, k) for k in [:id, :engine, :type, :execution_payload, :workflow_id])
end


#-----------------------------------------------------------------------------# Operations
@testset "Operations Direct" begin

    json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json"
    sidarthe_model = SimulationService.get_json(json_url).configuration
    @testset "simulate petrinet" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json"
        obj = SimulationService.get_json(json_url).configuration
        sys = SimulationService.amr_get(obj, ODESystem)
        op = Simulate(sys, (0.0, 99.0))
        call_op = OperationRequest() # to test callback
        call_op.id = "1"
        df = solve(op; callback = SimulationService.get_callback(call_op,SimulationService.Simulate))
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 99.0)
    end

    @testset "simulate stock and flow" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SIR_stockflow.json"
        obj = SimulationService.get_json(json_url)
        sys = SimulationService.amr_get(obj, ODESystem)
        op = Simulate(sys, (0.0, 99.0))
        df = solve(op; callback = nothing)
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 99.0)
    end

    @testset "simulate regnet" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/LV_sheep_foxes_regnet.json"
        obj = SimulationService.get_json(json_url)
        sys = SimulationService.amr_get(obj, ODESystem)
        op = Simulate(sys, (0.0, 99.0))
        df = solve(op; callback = nothing)
        @test df isa DataFrame
        @test extrema(df.timestamp) == (0.0, 99.0)
    end
    @testset "calibrate" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json"
        obj = SimulationService.get_json(json_url).configuration
        sys = SimulationService.amr_get(obj, ODESystem)
        priors = SimulationService.amr_get(obj, sys, Val(:priors))
        df = CSV.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/datasets/SIDARTHE_dataset.csv").body, DataFrame)
        data = SimulationService.amr_get(df, sys, Val(:data))
        num_chains = 4
        num_iterations = 100
        calibrate_method = "bayesian"
        ode_method = nothing
        op = OperationRequest() # to test callback
        op.id = "1"
        o = SimulationService.Calibrate(sys, (0.0, 89.0), priors, data, num_chains, num_iterations, calibrate_method, ode_method)

        dfsim, dfparam = solve(o, callback = SimulationService.get_callback(op,SimulationService.Calibrate))

        statenames = [unknowns(o.sys); getproperty.(observed(o.sys), :lhs)]
        @test names(dfsim) == vcat("timestamp",reduce(vcat,[string.("ensemble",i,"_", statenames) for i in 1:size(dfsim,2)÷length(statenames)]))
        @test names(dfparam) == string.(parameters(sys))

        calibrate_method = "local"
        o = SimulationService.Calibrate(sys, (0.0, 89.0), priors, data, num_chains, num_iterations, calibrate_method, ode_method)
        dfsim, dfparam = SimulationService.solve(o; callback = SimulationService.get_callback(op,SimulationService.Calibrate))

        calibrate_method = "global"
        o = SimulationService.Calibrate(sys, (0.0, 89.0), priors, data, num_chains, num_iterations, calibrate_method, ode_method)
        dfsim, dfparam = SimulationService.solve(o; callback = SimulationService.get_callback(op,SimulationService.Calibrate))

        statenames = [unknowns(o.sys);getproperty.(observed(o.sys), :lhs)]
        @test names(dfsim) == vcat("timestamp",string.(statenames))
        @test names(dfparam) == string.(parameters(sys))
    end

    @testset "ensemble-simulate petrinet" begin
        amrfiles = [SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRD_base_model01_petrinet.json"),
        SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRHD_base_model01_petrinet.json")]


        amrs = amrfiles

        obj = (
            model_configs = map(1:2) do i
                (id="model_config_id_$i", weight = i / sum(1:2), solution_mappings = (Infected = "I", Recovered = "R", Susceptible = "S"))
            end,
            models = amrs,
            timespan = (start = 0, var"end" = 40),
            engine = "sciml",
            extra = (; num_samples = 40)
        )

        # create ensemble-simulte
        o = SimulationService.OperationRequest()
        o.route = "ensemble-simulate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrs
        o.timespan = (0,40)
        en = SimulationService.EnsembleSimulate(o)

        sim_en_sol = SimulationService.solve(en, callback = nothing)

        # bad test, need something better
        @test names(sim_en_sol) == ["timestamp","Infected","Recovered","Susceptible"]

    end
    @testset "ensemble-simulate stockflow" begin
        amrfiles = [SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRD_stockflow.json"),
        SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIR_stockflow.json")]


        amrs = amrfiles

        obj = (
            model_configs = map(1:2) do i
                (id="model_config_id_$i", weight = i / sum(1:2), solution_mappings = (Infected = "I", Recovered = "R", Susceptible = "S"))
            end,
            models = amrs,
            timespan = (start = 0, var"end" = 40),
            engine = "sciml",
            extra = (; num_samples = 40)
        )

        # create ensemble-simulte
        o = SimulationService.OperationRequest()
        o.route = "ensemble-simulate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrs
        o.timespan = (0,40)
        en = SimulationService.EnsembleSimulate(o)

        sim_en_sol = SimulationService.solve(en, callback = nothing)

        # bad test, need something better
        @test names(sim_en_sol) == ["timestamp","Infected","Recovered","Susceptible"]

    end
    @testset "ensemble-calibrate petrinet" begin
        # more complex ensemble_calibrate
        amrs = [SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sirhd.json"),
        SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/seiarhds.json")]

        obj = (
            model_configs = [
                (id ="sirhd", weight = 1/3, solution_mappings = (Infected = "Infections", Hospitalizations = "hospitalized_population")),
                (id = "seirhds", weight = 2/3, solution_mappings = (Infected = "Cases", Hospitalizations = "hospitalized_population"))]
            ,
            models = amrs,
            timespan = (start = 0, var"end" = 40),
            engine = "sciml",
            extra = (; num_samples = 40)
        )

        o = OperationRequest()
        o.route = "ensemble-simulate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrs
        o.timespan = (0,40)
        en = SimulationService.EnsembleSimulate(o)
        sim_en_sol = SimulationService.solve(en, callback = nothing)
        # ensemble part
        o = OperationRequest()
        o.route = "ensemble-calibrate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrs
        o.timespan = (0,40)
        o.df = sim_en_sol
        en_cal = SimulationService.EnsembleCalibrate(o)
        cal_sol = SimulationService.solve(en_cal,callback = nothing)
        @test cal_sol[!,:sirhd] ≈ [0.3333333333333333] && cal_sol[!,:seirhds] ≈ [0.6666666666666666]
    end

    @testset "ensemble-calibrate stockflow" begin
        # more complex ensemble_calibrate
        amrfiles = [SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SEIRD_stockflow.json"),
        SimulationService.get_json("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/SIR_stockflow.json")]


        obj = (
            model_configs = [
                (id ="seir", weight = 1/3, solution_mappings = (Infected = "I", Recovered = "R")),
                (id = "sir", weight = 2/3, solution_mappings = (Infected = "I", Recovered = "R"))]
            ,
            models = amrfiles,
            timespan = (start = 0, var"end" = 40),
            engine = "sciml",
            extra = (; num_samples = 40)
        )

        o = OperationRequest()
        o.route = "ensemble-simulate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrfiles
        o.timespan = (0,40)
        en = SimulationService.EnsembleSimulate(o)
        sim_en_sol = SimulationService.solve(en, callback = nothing)
        # ensemble part
        o = OperationRequest()
        o.route = "ensemble-calibrate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = amrfiles
        o.timespan = (0,40)
        o.df = sim_en_sol
        en_cal = SimulationService.EnsembleCalibrate(o)
        cal_sol = SimulationService.solve(en_cal,callback = nothing)
        @test cal_sol[!,:seir] ≈ [0.3333333333333333] && cal_sol[!,:sir] ≈ [0.6666666666666666]
    end


    @testset "Real Calibrate Payload" begin
        json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/models/sidarthe.json"
        obj = SimulationService.get_json(json_url).configuration
        sys = SimulationService.amr_get(obj, ODESystem)
        priors = SimulationService.amr_get(obj, sys, Val(:priors))
        df = CSV.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/simulation-integration/main/data/datasets/SIDARTHE_dataset.csv").body, DataFrame)
        data = SimulationService.amr_get(df, sys, Val(:data))
        num_chains = 4
        num_iterations = 100
        calibrate_method = "global"
        ode_method = nothing

        o = SimulationService.Calibrate(sys, (0.0, 89.0), priors, data, num_chains, num_iterations, calibrate_method, ode_method)
        op = OperationRequest()
        op.id = "1"
        dfsim, dfparam = SimulationService.solve(o, callback = SimulationService.get_callback(op,SimulationService.Calibrate))

        statenames = [unknowns(o.sys);getproperty.(observed(o.sys), :lhs)]
        @test names(dfsim) == vcat("timestamp",string.(statenames))
    end
end


#-----------------------------------------------------------------------------# test routes
@testset "Server Routes" begin
    SimulationService.with_server() do url
        @testset "/health" begin
            res = HTTP.get("$url/health")
            @test res.status == 200
            @test JSON3.read(res.body).status == "ok"
        end

        @testset "/docs" begin
            res = HTTP.get("$url/docs")
            @test res.status == 200
        end

        # Check the status of a job until it finishes
        function test_until_done(id::String, every=2)
            t = now()
            while true
                st = get_json("$url/status/$id").status
                @info "status from job $(repr(id)) - ($(round(now() - t, Dates.Second))): $st"
                st in ["queued", "running", "complete"] && @test true
                st in ["failed", "error"] && (@test false; break)
                st == "complete" && break
                sleep(every)
            end
        end

        @testset "/simulate" begin
            for body in simulate_payloads
                res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
                @test res.status == 201
                id = JSON3.read(res.body).simulation_id
                test_until_done(id)
                @test SimulationService.last_operation[].result isa DataFrame
            end
        end

        @testset "/calibrate" begin
            for body in calibrate_payloads
                res = HTTP.post("$url/calibrate", ["Content-Type" => "application/json"]; body)
                @test res.status == 201
                id = JSON3.read(res.body).simulation_id
                test_until_done(id, 5)
            end
        end

        @testset "/ensemble-simulate" begin
            for body in simulate_ensemble_payloads
                res = HTTP.post("$url/ensemble-simulate", ["Content-Type" => "application/json"]; body)
                @test res.status == 201
                id = JSON3.read(res.body).simulation_id
                test_until_done(id)
            end
        end
        @testset "/ensemble-calibrate" begin
            for body in calibrate_ensemble_payloads
                res = HTTP.post("$url/ensemble-calibrate", ["Content-Type" => "application/json"]; body)
                @test res.status == 201
                id = JSON3.read(res.body).simulation_id
                test_until_done(id)
            end
        end
    end
end
