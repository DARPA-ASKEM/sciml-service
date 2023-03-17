"""
Deterministic Simulation Interface

EXPOSED:
- forecast   

NEEDED:
- fit
"""
module Deterministic

import AlgebraicPetri: LabelledPetriNet
import DataFrames: DataFrame
import DifferentialEquations: solve
import ModelingToolkit: ODESystem, ODEProblem, remake
import Symbolics: getname
import SymbolicIndexingInterface: states, parameters

export forecast

"""
Transform list of args into Symbolics variables     
"""
function symbolize_args(incoming_values, sys_vars)
    pairs = collect(incoming_values)
    symbols, values = Symbol(first.(pairs)), last.(pairs)
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
function forecast(; petri::LabelledPetriNet, params, initials, tspan=(0.0, 100.0))
    # Convert PetriNet to ODEProblem
    # TODO(five): Break out conversion into separate function maybe?
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
    sol = solve(prob)
    DataFrame(sol)
end

end # module Deterministic

