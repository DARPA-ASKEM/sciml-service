using Scheduler, AlgebraicPetri, DataFrames, DifferentialEquations, ModelingToolkit, Symbolics, EasyModelAnalysis, Catlab, Catlab.CategoricalAlgebra, JSON3, UnPack, Scheduler.SciMLInterface.SciMLOperations
using CSV, DataFrames, JSONTables
_datadir() = joinpath(dirname(Base.active_project()), "examples")
_data(s) = joinpath(_datadir(), s)

_logdir() = joinpath(@__DIR__, "logs")
_log(s) = joinpath(_logdir(), s)
mkpath(_logdir())

bn = "BIOMD0000000955_miranet.json"
fn = _data(bn)
T = PropertyLabelledReactionNet{Number,Number,Dict}
TAny = PropertyLabelledReactionNet{Any,Any,Any}

# we should be able to assume that all concentration and rate are set (despite this not being the case for the other 2 Miras from ben)
petri = read_json_acset(T, fn)
ps = string.(tnames(petri)) .=> petri[:rate]
u0 = string.(snames(petri)) .=> petri[:concentration]

params = Dict(ps)
initials = Dict(u0)
tspan = (0.0, 100.0)

nt = (; petri, params, initials, tspan)
body = Dict(pairs(nt))
j = JSON3.write(body)
forecast_fn = _log("forecast.json")
write(forecast_fn, j)

df = Scheduler.SciMLInterface.forecast(; nt...)
@test df isa DataFrame

params["t1"] = 0.1
nt = (; petri, params, initials, tspan)
df2 = Scheduler.SciMLInterface.forecast(; nt...)

t = df.timestamp
data = Dict(["Susceptible" => df[:, 2]])
fit_args = (; petri, params, initials, t, data)
fit_body = Dict(pairs(fit_args))
fit_j = JSON3.write(fit_body)
calibrate_fn = _log("calibrate.json")
write(calibrate_fn, fit_j)

fitp = Scheduler.SciMLInterface._datafit(; fit_args...)
prob = SciMLOperations._to_prob(petri, params, initials, extrema(t))

sys = prob.f.sys
p = SciMLOperations.symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
@show p
# hack since datafit has a dumb signature restriction with Num
ks, vs = unzip(collect(p))
p = Num.(ks) .=> vs
data2 = SciMLOperations.symbolize_args(data, states(sys))
fitp = EasyModelAnalysis.datafit(prob, p, t, data2)
