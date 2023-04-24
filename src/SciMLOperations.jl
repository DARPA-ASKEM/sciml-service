"""
SciML Operation definitions
"""
module SciMLOperations

import Logging: global_logger
include("./Queuing.jl"); import .Queuing: MQLogger, shouldlog, min_enabled_level, handle_message, get_publish_json_hook
global_logger(MQLogger(get_publish_json_hook()))


import AlgebraicPetri: LabelledPetriNet, AbstractPetriNet
import DataFrames: DataFrame
import DifferentialEquations: solve
import ModelingToolkit: ODESystem, ODEProblem, remake
import Symbolics: getname, Num
import SymbolicIndexingInterface: states, parameters
import EasyModelAnalysis

export forecast, calibrate

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
function forecast(; petri::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    tspan=(0.0, 100.0)::Tuple{Float64,Float64}
)::DataFrame
    sol = solve(_to_prob(petri, params, initials, tspan); progress = true, progress_steps = 1)
    DataFrame(sol)
end

"
for custom loss functions, we probably just allow an enum of functions defined in EMA. (todo)

    datafit is exported in EMA 
"
function calibrate(; petri::AbstractPetriNet,
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    timesteps::Vector{Float64},
    data::Dict{String,Vector{Float64}},
)
    prob = _to_prob(petri, params, initials, extrema(timesteps))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    @show p
    ks, vs = unzip(collect(p))
    p = Num.(ks) .=> vs
    data = SciMLOperations.symbolize_args(data, states(sys))
    fitp = EasyModelAnalysis.datafit(prob, p, timesteps, data)
    @info fitp
    # DataFrame(fitp)
    fitp
end

"long running functions like global_datafit and sensitivity wrappers will need to be refactored to share callback info incrementally"
function _global_datafit(; petri::LabelledPetriNet,
    parameter_bounds::Dict{String,Tuple{Float64,Float64}},
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    t::Vector{Number},
    data::Dict{String,Vector{Float64}}
)::DataFrame
    ks, vs = unzip(parameter_bounds)
    @assert all(issorted.(vs))
    prob = to_prob(petri, params, initials, extrema(t))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = global_datafit(prob, collect(p), t, data)
    DataFrame(fitp)
end

end # module SciMLOperations

