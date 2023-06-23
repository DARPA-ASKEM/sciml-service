"""
User-provided, problem-specific inputs
"""
module ProblemInputs

import AlgebraicPetri: PropertyLabelledPetriNet, LabelledPetriNet, AbstractPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import DataFrames: DataFrame
import CSV
import JSON

export conversions_for_valid_inputs

"""
Transform string into dataframe before it is used as input    
"""
coerce_dataset(val::String) = CSV.read(IOBuffer(val), DataFrame)

"""
Act as identity since the value is already coerced    
"""
coerce_dataset(val::DataFrame) = val

struct ASKEMModel
    petri::PropertyLabelledPetriNet
    json::AbstractDict
end

"""
Transform payload in ASKEM model rep into ACSet
"""
function coerce_model(val)
    parsed = JSON.Parser.parse(val)
    model = parsed["model"]
    state_props = Dict(Symbol(s["id"]) => s for s in model["states"])
    states = [Symbol(s["id"]) for s in model["states"]]
    transition_props = Dict(Symbol(t["id"]) => t["properties"] for t in model["transitions"])
    transitions = [Symbol(t["id"]) => (Symbol.(t["input"]) => Symbol.(t["output"])) for t in model["transitions"]]

    petri = PropertyLabelledPetriNet{Dict}(LabelledPetriNet(states, transitions...), state_props, transition_props)
    ASKEMModel(petri, parsed)
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
