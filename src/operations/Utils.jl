"""
Unexposed helper functions for operations
"""
module Utils

import DataFrames: DataFrame, names
import ModelingToolkit: ODESystem, ODEProblem
import Symbolics: getname, @variables, substitute
import SymbolicIndexingInterface: states, parameters
import MathML

export to_prob, unzip, symbolize_args, select_data

"""
Transform model representation into a SciML ODEProblem
"""
function to_prob(sys, tspan)
    ODEProblem(sys; tspan, saveat=1)
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
function select_data(dataframe::DataFrame)
    data = Dict(
        key => dataframe[!, key]
        for key in names(dataframe) if key != "timestep"
    )

    dataframe[!, "timestep"], data
end


end # module Utils.jl
