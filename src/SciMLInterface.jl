"""
Shared source of truth for operations and scheduler    
"""
module SciMLInterface

import AlgebraicPetri: PropertyLabelledReactionNet, LabelledPetriNet, AbstractPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, @post, @get
import CSV: write
import DataFrames: DataFrame
import HTTP: Request
import HTTP.Exceptions: StatusError
# import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./SciMLOperations.jl")
import .SciMLOperations: forecast, calibrate, _global_datafit

export sciml_operations, conversions_for_valid_inputs

"""
Sim runs that can be created using the `/runs/sciml/{operation}` endpoint.    
"""
sciml_operations = Dict{Symbol,Function}(
    :forecast => forecast,
    :calibrate => calibrate
    # :global_calibrate => _global_datafit
    # TODO(five): Add `ensemble` operation
)

"""
Inputs converted from payload to arguments expanded in operations.    
"""
conversions_for_valid_inputs = Dict{Symbol,Function}(
    :petri => (val) -> parse_json_acset(PropertyLabelledReactionNet{Number, Number, Dict}, val), # hack for mira
    :tspan => (val) -> Tuple{Float64,Float64}(val),
    :params => (val) -> Dict{String,Float64}(val),
    :initials => (val) -> Dict{String,Float64}(val),
    :data => (val) -> Dict{String, Vector{Float64}}(val),
    :timesteps => (val) -> Vector{Float64}(val)
)


end # module SciMLInterface
