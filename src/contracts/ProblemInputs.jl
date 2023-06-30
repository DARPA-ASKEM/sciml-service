"""
User-provided, problem-specific inputs
"""
module ProblemInputs

import AlgebraicPetri: PropertyLabelledPetriNet, LabelledPetriNet, AbstractPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import ModelingToolkit: @parameters, substitute, Differential, Num, @variables, ODESystem
import DataFrames: DataFrame
import CSV
import JSON
import MathML

export conversions_for_valid_inputs

"""
Transform string into dataframe before it is used as input
"""
coerce_dataset(val::String) = CSV.read(IOBuffer(val), DataFrame)

"""
Act as identity since the value is already coerced
"""
coerce_dataset(val::DataFrame) = val

"""
Transform payload in ASKEM model rep into an ODESystem
"""
function coerce_model(val)
    obj = JSON.Parser.parse(val)
    model = obj["model"]
    ode = obj["semantics"]["ode"]

    t = only(@variables t)
    D = Differential(t)

    statenames = [Symbol(s["id"]) for s in model["states"]]
    statevars  = [only(@variables $s) for s in statenames]
    statefuncs = [only(@variables $s(t)) for s in statenames]

    # get parameter values and state initial values
    paramnames = [Symbol(x["id"]) for x in ode["parameters"]]
    paramvars = [only(@parameters $x) for x in paramnames]
    paramvals = [x["value"] for x in ode["parameters"]]
    sym_defs = paramvars .=> paramvals
    initial_exprs = [MathML.parse_str(x["expression_mathml"]) for x in ode["initials"]]
    initial_vals = map(x->substitute(x, sym_defs), initial_exprs)

    # build equations from transitions and rate expressions
    rates = Dict(Symbol(x["target"]) => MathML.parse_str(x["expression_mathml"]) for x in ode["rates"])
    eqs = Dict(s => Num(0) for s in statenames)
    for tr in model["transitions"]
        ratelaw = rates[Symbol(tr["id"])]
        for s in tr["input"]
            s = Symbol(s)
            eqs[s] = eqs[s] - ratelaw
        end
        for s in tr["output"]
            s = Symbol(s)
            eqs[s] = eqs[s] + ratelaw
        end
    end

    subst = Dict(zip(statevars, statefuncs))
    eqs = [D(statef) ~ substitute(eqs[state], subst) for (state, statef) in zip(statenames, statefuncs)]

    ODESystem(eqs, t, statefuncs, paramvars; defaults = [statefuncs .=> initial_vals; sym_defs], name=Symbol(obj["name"]))
end

"""
Coerce timespan
"""
coerce_timespan(val) = !isnothing(val) ? Tuple{Float64,Float64}(val) : nothing

"""
Inputs converted from payload to arguments expanded in operations.
"""
conversions_for_valid_inputs = Dict{Symbol,Function}(
    :model => coerce_model,
    :models => val -> coerce_model.(val),
    :timespan => coerce_timespan,
    :params => (val) -> Dict{String,Float64}(val),
    :initials => (val) -> Dict{String,Float64}(val),
    :dataset => coerce_dataset,
)

end # module ProblemInputs
