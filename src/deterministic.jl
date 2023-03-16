module Deterministic

import AlgebraicPetri: LabelledPetriNet
import ModelingToolkit: ODESystem, ODEProblem, remake, solve
import Symbolics: getname
import SymbolicIndexingInterface: states, parameters

# using AlgebraicPetri, Catlab, JSON, JSON3, JSONTables, CSV, DataFrames, Oxygen, HTTP
# using Catlab.CategoricalAlgebra
# using Catlab.CategoricalAlgebra.FinSets
# using ModelingToolkit, OrdinaryDiffEq, DifferentialEquations
# using OrderedCollections, NamedTupleTools

function symbolize_args(incoming_values, sys_symbols)
    # In this context, standard symbols will be called vars as to not confilct with `Symbolics` symbols
    pairs = collect(incoming_values)
    incoming_vars, values = Symbol(first.(pairs)), last.(pairs)
    symbols_as_vars = getname.(sys_symbols)
    vars_to_symbols = Dict(symbols_as_vars .=> sys_symbols)
    Dict([vars_to_symbols[symbols_as_vars[findfirst(x -> x == symbol, symbols_as_vars)]] for symbol in incoming_vars] .=> values)
end

function solve(petri::LabelledPetriNet, params, initials, tspan=(0.0, 100.0))
    # Convert PetriNet to ODEProblem
    sys = ODESystem(petri)
    sts = states(sys)
    ps = parameters(sys)
    defaults = [sts .=> zeros(length(sts)); ps .=> zeros(length(ps))]
    sys = ODESystem(petri; defaults=defaults, tspan=(0.0, 100.0))
    prob = ODEProblem(sys)

    prob = remake(prob;
        u0=symbolize_args(initials, sts),
        p=symbolize_args(params, ps),
        tspan=tspan
    )
    solve(prob)
end

export solve

end # module Deterministic

