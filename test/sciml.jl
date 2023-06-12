using SimulationService, AlgebraicPetri, DataFrames, DifferentialEquations, ModelingToolkit, Symbolics, EasyModelAnalysis, Catlab, Catlab.CategoricalAlgebra, JSON3, UnPack, SimulationService.Service.Execution.Interface.Operations
using CSV, DataFrames, JSONTables
using ForwardDiff

_datadir() = joinpath(@__DIR__, "../examples")
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
timespan = (0.0, 100.0)

nt = (; model=petri, params, initials, timespan)
body = Dict(pairs(nt))
j = JSON3.write(body)
forecast_fn = _log("forecast.json")
write(forecast_fn, j)

df = SimulationService.Service.Execution.Interface.get_operation(:simulate)(; nt..., context=nothing)
@test df isa DataFrame

params["t1"] = 0.1
nt = (; model = petri, params, initials, timespan)
df2 = SimulationService.Service.Execution.Interface.get_operation(:simulate)(; nt..., context=nothing)

timesteps = df.timestamp
data = Dict(["Susceptible" => df[:, 2]])
rename!(df, Dict("Susceptible(t)" => "Susceptible", "timestamp" => "timestep"))
fit_args = (; model=petri, params, initials, dataset=df[:, ["timestep", "Susceptible"]])
fit_body = Dict(pairs(fit_args))
fit_j = JSON3.write(fit_body)
calibrate_fn = _log("calibrate.json")
write(calibrate_fn, fit_j)

fitp = SimulationService.Service.Execution.Interface.get_operation(:calibrate_plain)(; fit_args..., context=nothing)
prob = SimulationService.Service.Execution.Interface.Operations.Utils.to_prob(petri, params, initials, extrema(timesteps))
sys = prob.f.sys

# example of dloss/dp
pkeys = parameters(sys)
pvals = [params[string(x)] for x in pkeys]
data = [states(sys)[1] => df[:, 2]]

l = EasyModelAnalysis.l2loss(pvals, (prob, pkeys, timesteps, data))
ForwardDiff.gradient(p -> EasyModelAnalysis.l2loss(p, (prob, pkeys, timesteps, data)), last.(fitp))
