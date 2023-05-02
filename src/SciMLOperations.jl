"""
SciML Operation definitions
"""
module SciMLOperations

import AlgebraicPetri: LabelledPetriNet, AbstractPetriNet
import DataFrames: DataFrame
import DifferentialEquations: solve
import ModelingToolkit: ODESystem, ODEProblem, remake
import Symbolics: getname, Num
import SymbolicIndexingInterface: states, parameters
import EasyModelAnalysis

export forecast, calibrate

_to_prob(model, params, initials, tspan) = begin
    sys = ODESystem(model)
    u0 = _symbolize_args(initials, states(sys))
    p = _symbolize_args(params, parameters(sys))
    ODEProblem(sys, u0, tspan, p; saveat=1)
end

_unzip(d::Dict) = (collect(keys(d)), collect(values(d)))
unzip(ps) = first.(ps), last.(ps)

"""
Transform list of args into Symbolics variables     
"""
function _symbolize_args(incoming_values, sys_vars)
    pairs = collect(incoming_values)
    ks, values = unzip(pairs)
    symbols = Symbol.(ks)
    vars_as_symbols = getname.(sys_vars)
    symbols_to_vars = Dict(vars_as_symbols .=> sys_vars)
    Dict(
        [
            symbols_to_vars[vars_as_symbols[findfirst(x -> x == symbol, vars_as_symbols)]]
            for symbol in symbols
        ] .=> values
    )
end

function _select_data(dataframe::DataFrame, feature_mappings:: Dict{String, String}, timesteps_column::String)
    data = Dict(
        to => dataframe[!, from]
        for (from, to) in feature_mappings 
    )
    dataframe[!, timesteps_column], data
end

"""
Simulate a scenario from a PetriNet    
"""
function forecast(; model::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    tspan=(0.0, 100.0)::Tuple{Float64,Float64}
)::DataFrame
    sol = solve(_to_prob(model, params, initials, tspan); progress = true, progress_steps = 1)
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
    feature_mappings::Dict{String, String},
    timesteps_column::String = "timestamp"
)
    timesteps, data = _select_data(dataset, feature_mappings, timesteps_column)
    prob = _to_prob(model, params, initials, extrema(timesteps))
    sys = prob.f.sys
    p = _symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    @show p
    ks, vs = unzip(collect(p))
    p = Num.(ks) .=> vs
    data = SciMLOperations._symbolize_args(data, states(sys))
    fitp = EasyModelAnalysis.datafit(prob, p, timesteps, data)
    @info fitp
    # DataFrame(fitp)
    fitp
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
    p = _symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = global_datafit(prob, collect(p), t, data)
    DataFrame(fitp)
end

end # module SciMLOperations

