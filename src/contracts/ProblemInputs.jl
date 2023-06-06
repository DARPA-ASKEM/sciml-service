"""
User-provided, problem-specific inputs
"""
module ProblemInputs

import AlgebraicPetri: PropertyLabelledReactionNet, LabelledPetriNet, AbstractPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import DataFrames: DataFrame
import CSV

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
Inputs converted from payload to arguments expanded in operations.    
"""
conversions_for_valid_inputs = Dict{Symbol,Function}(
    :model => (val) -> parse_json_acset(PropertyLabelledReactionNet{Number, Number, Dict}, val), # hack for mira
    :tspan => (val) -> Tuple{Float64,Float64}(val),
    :params => (val) -> Dict{String,Float64}(val),
    :initials => (val) -> Dict{String,Float64}(val),
    :dataset => coerce_dataset,
    :feature_mappings => (val) -> Dict{String, String}(val),
    :timesteps_column => (val) -> String(val)
)

end # module ProblemInputs