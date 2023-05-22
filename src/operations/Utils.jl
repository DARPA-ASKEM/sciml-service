"""
Unexposed helper functions for operations    
"""
module Utils

import DataFrames: DataFrame
import ModelingToolkit: ODESystem, ODEProblem
import Symbolics: getname
import SymbolicIndexingInterface: states, parameters

export to_prob, unzip, symbolize_args, select_data

"""
Transform model representation into a SciML primitive, an ODEProblem
"""
to_prob(model, params, initials, tspan) = begin
    sys = ODESystem(model)
    u0 = symbolize_args(initials, states(sys))
    p = symbolize_args(params, parameters(sys))
    ODEProblem(sys, u0, tspan, p; saveat=1)
end

"""
Separate keys and values    
"""
unzip(d::Dict) = (collect(keys(d)), collect(values(d)))

"""
Unzip a collection of pairs    
"""
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
Generate data and timestep list from a dataframe    
"""
function select_data(dataframe::DataFrame, feature_mappings:: Dict{String, String}, timesteps_column::String)
    data = Dict(
        to => dataframe[!, from]
        for (from, to) in feature_mappings 
    )
    dataframe[!, timesteps_column], data
end


end # module Utils.jl
