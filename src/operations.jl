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
    if o.last_callback + o.every ≤ Dates.now(UTC)
        o.last_callback = Dates.now(UTC)
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
    priors::Any # ???
    data::Any # ???
end

function Calibrate(o::OperationRequest)
    sys = amr_get(o.model, ODESystem)
    priors = amr_get(o.model, sys, Val(:priors))
    data = o.df
    Calibrate(sys, o.timespan, priors, data)
end

function solve(o::Calibrate; callback)
    prob = ODEProblem(o.sys, [], o.timespan)
    names = [states(o.sys);getproperty.(observed(o.sys), :lhs)]

    # what the data should be like
    # o.data
    tsave1 = collect(10.0:10.0:100.0)
    sol_data1 = solve(prob, saveat = tsave1)
    tsave2 = collect(10.0:13.5:100.0)
    sol_data2 = solve(prob, saveat = tsave2)
    data_with_t = [x => (tsave1, sol_data1[x]), z => (tsave2, sol_data2[z])]

    p_posterior = bayesian_datafit(prob, o.priors, data_with_t)

    probs = [remake(prob, p = Pair.(first.(p_posterior), getindex.(p_posterior.(fit), i))) for i in 1:length(p_posterior[1][2])]
    enprob = EnsembleProblem(probs)
    ensol = solve(enprob, saveat = 1)
    soldata = DataFrame([sol.t;Matrix(sol[names])'])
    rename!(soldata, names)

    df = DataFrame(last.(p_posterior), :auto)
    rename!(df, Symbol.(first.(p_posterior)))

    df, soldata
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
