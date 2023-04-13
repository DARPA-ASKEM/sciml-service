"""
SciML Operation definitions
"""
module SciMLOperations

import AlgebraicPetri: LabelledPetriNet
import DataFrames: DataFrame
import DifferentialEquations: solve
import ModelingToolkit: ODESystem, ODEProblem, remake
import Symbolics: getname
import SymbolicIndexingInterface: states, parameters
import EasyModelAnalysis

export forecast

_to_prob(petri, params, initials, tspan) = begin
    sys = ODESystem(petri)
    u0 = symbolize_args(initials, states(sys))
    p = symbolize_args(params, parameters(sys))
    ODEProblem(sys, u0, tspan, p; saveat=1)
end

_unzip(d::Dict) = (collect(keys(d)), collect(values(d)))
unzip(ps) = first.(ps), last.(ps)

"""
Transform list of args into Symbolics variables     
"""
function symbolize_args(incoming_values, sys_vars)
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

"""
Simulate a scenario from a PetriNet    
"""
function forecast(; petri::LabelledPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    tspan=(0.0, 100.0)::Tuple{Float64,Float64}
)::DataFrame
    # Convert PetriNet to ODEProblem
    # TODO(five): Break out conversion into separate function maybe?
    sol = solve(_to_prob(petri, params, initials, tspan))
    DataFrame(sol)
end

"
for custom loss functions, we probably just allow an enum of functions defined in EMA. (todo)

    datafit is exported in EMA 
"
function _datafit(; petri::LabelledPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    t::Vector{Number},
    data::Dict{String,Vector{Float64}}
)::DataFrame
    prob = to_prob(petri, params, initials, extrema(t))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = datafit(prob, collect(p), t, data)
    DataFrame(fitp)
end

_val_bound(b) = @assert issorted(b)

function _global_datafit(; petri::LabelledPetriNet,
    parameter_bounds::Dict{String,Tuple{Float64, Float64}},
    initials::Dict{String,Float64},
    t::Vector{Number},
    data::Dict{String,Vector{Float64}}
)::DataFrame
    ks, vs = unzip(parameter_bounds)
    _val_bound.(vs)
    prob = to_prob(petri, params, initials, extrema(t))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = global_datafit(prob, collect(p), t, data)
    DataFrame(fitp)

end

end # module SciMLOperations

