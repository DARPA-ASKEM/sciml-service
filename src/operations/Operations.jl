"""
SciML Operation definitions
"""
module Operations

import AlgebraicPetri: LabelledPetriNet, AbstractPetriNet
import DataFrames: DataFrame
import DifferentialEquations: solve
import ModelingToolkit: remake
import Symbolics: Num
import SymbolicIndexingInterface: states, parameters
import EasyModelAnalysis

include("./Utils.jl"); import .Utils: to_prob, unzip, symbolize_args, select_data

# NOTE: Operations exposed to the rest of the Simulation Service
export simulate, calibrate, ensemble

"""
Simulate a scenario from a PetriNet
"""
# model::ASKEMModel
function simulate(; model, timespan::Tuple{Float64,Float64}=(0.0, 100.0), context)::DataFrame
    sol = solve(to_prob(model, timespan); progress = true, progress_steps = 1)
    DataFrame(sol)
end

"
for custom loss functions, we probably just allow an enum of functions defined in EMA. (todo)

    datafit is exported in EMA
"
# model::ASKEMModel
function calibrate(; model, dataset::DataFrame, context)
    timesteps, data = select_data(dataset)
    prob = to_prob(model, extrema(timesteps))
    p = Vector{Pair{Num, Float64}}([Num(param) => model.defaults[param] for param in parameters(model)])
    @show p
    data = symbolize_args(data, states(model))
    fitp = EasyModelAnalysis.datafit(prob, p, timesteps, data)
    @info fitp
    # DataFrame(fitp)
    fitp
end

"""
Simulate an ensemble of models
"""
function ensemble(; models::AbstractVector, timespan=(0.0, 100.0)::Tuple{Float64, Float64})
    probs = map(m->to_prob(m, timespan), models)
    prob_func(prob, i, rep) = remake(probs[i])
    enprob = EnsembleProblem(probs[1]; prob_func)
    sol = solve(enprob; saveat=1, trajectories=length(probs))
    map(DataFrame, sol)
end

"long running functions like global_datafit and sensitivity wrappers will need to be refactored to share callback info incrementally"
function _global_datafit(; model::LabelledPetriNet,
    parameter_bounds::Dict{String,Tuple{Float64,Float64}},
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    t::Vector{Number},
    data::Dict{String,Vector{Float64}}
)::DataFrame
    ks, vs = unzip(parameter_bounds)
    @assert all(issorted.(vs))
    prob = to_prob(model, params, initials, extrema(t))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = global_datafit(prob, collect(p), t, data)
    DataFrame(fitp)
end

end # module Operations
