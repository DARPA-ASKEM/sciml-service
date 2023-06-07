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

include("./Utils.jl")
import .Utils: to_prob, unzip, symbolize_args, select_data

# NOTE: Export symbols here are automatically made available to the API (`/calls/{name}`)
export simulate, calibrate

"""
Simulate a scenario from a PetriNet    
"""
function simulate(; model::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    tspan=(0.0, 100.0)::Tuple{Float64,Float64},
    context
)::DataFrame
    sol = solve(to_prob(model, params, initials, tspan); progress=true, progress_steps=1)
    DataFrame(sol)
end

"
for custom loss functions, we probably just allow an enum of functions defined in EMA. (todo)

    datafit is exported in EMA 
"
function calibrate(; model::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    dataset::DataFrame,
    feature_mappings::Dict{String,String},
    timesteps_column::String="timestamp",
    context
)
    timesteps, data = select_data(dataset, feature_mappings, timesteps_column)
    prob = to_prob(model, params, initials, extrema(timesteps))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    # @show p
    ks, vs = unzip(collect(p))
    p = Num.(ks) .=> vs

    pbounds = Num.(ks) .=> fill((0.0, Inf,), length(ks)) # specific to Petri
    data = symbolize_args(data, states(sys))
    solve_kws = isnothing(context) ? (;) : (; callback=context.interactivity_hook)
    fitp = EasyModelAnalysis.global_datafit(prob, pbounds, timesteps, data; solve_kws)
    fitp
end


function ensemble_calibrate(args;kws...)
    [calibrate(;fit_args..., kws...) for fit_args in args]
end

end # module Operations 
