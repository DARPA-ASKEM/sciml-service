#--------------------------------------------------------------------# IntermediateResults callback
# Publish intermediate results to RabbitMQ with at least `every` seconds inbetween callbacks
mutable struct IntermediateResults
    last_callback::Dates.DateTime  # Track the last time the callback was called
    every::Dates.TimePeriod  # Callback frequency e.g. `Dates.Second(5)`
    id::String
    function IntermediateResults(id::String; every=Dates.Second(5))
        new(typemin(Dates.DateTime), every, id)
    end
end
function (o::IntermediateResults)(integrator)
    if o.last_callback + o.every ≤ Dates.now()
        o.last_callback = Dates.now()
        (; iter, t, u, uprev) = integrator
        publish_to_rabbitmq(; iter=iter, time=t, params=u, abserr=norm(u - uprev), id=o.id,
            retcode=SciMLBase.check_error(integrator))
    end
end

get_callback(o::OperationRequest) = DiscreteCallback((args...) -> true, IntermediateResults(o.id))


#-----------------------------------------------------------------------------# Operations
# An Operation requires:
#  1) an Operation(::OperationRequest) constructor
#  2) a solve(::Operation; callback) method
#
# An Operation's fields should be separate from any request-specific things for ease of testing.
abstract type Operation end

function dataframe_with_observables(sol::ODESolution)
    sys = sol.prob.f.sys
    names = [states(sys); getproperty.(observed(sys), :lhs)]
    cols = ["timestamp" => sol.t; [string(n) => sol[n] for n in names]]
    DataFrame(cols)
end

#-----------------------------------------------------------------------------# simulate
struct Simulate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
end

function Simulate(o::OperationRequest)
    sys = amr_get(o.model, ODESystem)
    Simulate(sys, o.timespan)
end

function solve(op::Simulate; kw...)
    # joshday: What does providing `u0 = []` do?  Don't we know what u0 is from AMR?
    prob = ODEProblem(op.sys, [], op.timespan, saveat=1)
    sol = solve(prob; progress = true, progress_steps = 1, kw...)
    dataframe_with_observables(sol)
end

#-----------------------------------------------------------------------------# Calibrate
struct Calibrate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
    priors::Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Uniform{Float64}}}
    data::Any
    num_chains::Int
    num_iterations::Int
    calibrate_method::String
    ode_method::Any
end

function Calibrate(o::OperationRequest)
    sys = amr_get(o.model, ODESystem)
    priors = amr_get(o.model, sys, Val(:priors))
    data = amr_get(o.df, sys, Val(:data))

    num_chains = 4
    num_iterations = 100
    calibrate_method = "bayesian"
    ode_method = nothing

    if :extra in keys(o.obj)
        extrakeys = keys(o.obj.extra)
        :num_chains in extrakeys && (num_chains = o.extra.num_chains)
        :num_iterations in extrakeys && (num_iterations = o.extra.num_iterations)
        :calibrate_method in extrakeys && (calibrate_method = o.extra.calibrate_method)
    end
    Calibrate(sys, o.timespan, priors, data, num_chains, num_iterations, calibrate_method, ode_method)
end

function solve(o::Calibrate; callback)
    prob = ODEProblem(o.sys, [], o.timespan)
    statenames = [states(o.sys);getproperty.(observed(o.sys), :lhs)]

    if o.calibrate_method == "bayesian"
        p_posterior = EasyModelAnalysis.bayesian_datafit(prob, o.priors, o.data;
                                                        nchains = 2,
                                                        niter = 100,
                                                        mcmcensemble = SimulationService.EasyModelAnalysis.Turing.MCMCSerial())

        pvalues = last.(p_posterior)

        probs = [EasyModelAnalysis.remake(prob, p = Pair.(first.(p_posterior), getindex.(pvalues,i))) for i in 1:length(p_posterior[1][2])]
        enprob = EasyModelAnalysis.EnsembleProblem(probs)
        ensol = solve(enprob, saveat = 1)
        outs = map(1:length(probs)) do i
            mats = stack(ensol[i][statenames])'
            headers = string.("ensemble",i,"_", statenames)
            mats, headers
        end
        dfsim = DataFrame(hcat(ensol[1].t, reduce(hcat, first.(outs))), :auto)
        rename!(dfsim, ["timestamp";reduce(vcat, last.(outs))])

        dfparam = DataFrame(last.(p_posterior), :auto)
        rename!(dfparam, Symbol.(first.(p_posterior)))

        dfsim, dfparam
    elseif o.calibrate_method == "local" || o.calibrate_method == "global"
        if o.calibrate_method == "local"
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), Statistics.mean.(last.(o.priors)))
            fit = EasyModelAnalysis.datafit(prob, init_params, o.data)
        else
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), tuple.(minimum.(last.(o.priors)), maximum.(last.(o.priors))))
            fit = global_datafit(prob, init_params, o.data)
        end

        newprob = remake(prob, p=fit)
        sol = solve(newprob)
        dfsim = DataFrame(hcat(sol.t,stack(sol[statenames])'), :auto)
        rename!(dfsim, ["timestamp";string.(statenames)])

        dfparam = DataFrame(Matrix(last.(fit)'), :auto)
        rename!(dfparam, Symbol.(first.(fit)))

        dfsim, dfparam
    else
        error("$(o.calibrate_method) is not a valid choice of calibration method")
    end
end

#-----------------------------------------------------------------------------# Ensemble
struct Ensemble <: Operation
    sys::Vector{ODESystem}
    priors::Vector{Pair{Num,Any}} # Any = Distribution
    train_datas::Any
    ensem_datas::Any
    t_forecast::Vector{Float64}
    quantiles::Vector{Float64}
end

Ensemble(o::OperationRequest) = error("TODO")

function solve(o::Ensemble; callback)
    probs = [ODEProblem(s, [], o.timespan) for s in sys]
    ps = [[β => Uniform(0.01, 10.0), γ => Uniform(0.01, 10.0)] for i in 1:3]
    datas = [data_train,data_train,data_train]
    enprobs = bayesian_ensemble(probs, ps, datas)
    ensem_weights = ensemble_weights(sol, data_ensem)

    forecast_probs = [remake(enprobs.prob[i]; tspan = (t_train[1],t_forecast[end])) for i in 1:length(enprobs.prob)]
    fit_enprob = EnsembleProblem(forecast_probs)
    sol = solve(fit_enprob; saveat = o.t_forecast);

    soldata = DataFrame([sol.t;Matrix(sol[names])'])

    # Requires https://github.com/SciML/SciMLBase.jl/pull/467
    # weighted_ensem = WeightedEnsembleSolution(sol, ensem_weights; quantiles = o.quantiles)
    # df = DataFrame(weighted_ensem)
    # df, soldata
end
#-----------------------------------------------------------------------------# All operations
# :simulate => Simulate, etc.
const OPERATIONS_LIST = Dict(Symbol(lowercase(string(T.name.name))) => T for T in subtypes(Operation))
