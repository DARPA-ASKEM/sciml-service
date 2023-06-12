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

# NOTE: Export symbols here are automatically made available to POSTs on `/{name}`)
export simulate, calibrate_plain, calibrate, ensemble

"""
Simulate a scenario from a PetriNet    
"""
function simulate(; model::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    timespan=(0.0, 100.0)::Tuple{Float64,Float64},
    context
)::DataFrame
    sol = solve(to_prob(model, params, initials, timespan); progress = true, progress_steps = 1)
    DataFrame(sol)
end

"""
Calibrate + Simulate
"""
function calibrate(; model::AbstractPetriNet, # TODO(five): Remove from exports and rename
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    dataset::DataFrame,
    timespan::Union{Nothing, Tuple{Float64, Float64}} = nothing,
    context,
)
    calibrated_params = calibrate_plain(;model=model, params=params, initials=initials, dataset=dataset, context=context)
    if in(NaN, values(calibrated_params)) throw("NaN adjustment") end
    adjusted_params = Dict(key.val => value for (key,value) in calibrated_params)

    timesteps, _ = select_data(dataset, feature_mappings, timesteps_column)
    [
        calibrated_params,
        simulate(;model=model, params=params, initials=initials, timespan=(Float64(timesteps[1]), Float64(timesteps[end])), context),
        !isnothing(timespan) ? simulate(;model=model, params=params, initials=initials, timespan=timespan, context) : nothing,
    ]

end


"
for custom loss functions, we probably just allow an enum of functions defined in EMA. (todo)

    datafit is exported in EMA 
"
function calibrate_plain(; model::AbstractPetriNet, # TODO(five): Remove from exports and rename
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    dataset::DataFrame,
    context,
)
    timesteps, data = select_data(dataset)
    prob = to_prob(model, params, initials, extrema(timesteps))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    @show p
    ks, vs = unzip(collect(p))
    p = Num.(ks) .=> vs
    data = symbolize_args(data, states(sys))
    fitp = EasyModelAnalysis.datafit(prob, p, timesteps, data)
    @info fitp
    # DataFrame(fitp)
    fitp
end

"""
NOT IMPLEMENTED    
"""
function ensemble(; models::AbstractArray{AbstractPetriNet}, timespan=(0.0, 100.0)::Tuple{Float64, Float64})
    throw("ENSEMBLE IS NOT YET IMPLEMENTED")
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
