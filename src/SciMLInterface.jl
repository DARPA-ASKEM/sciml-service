"""
Shared source of truth for operations and REST API
"""
module SciMLInterface


import Logging: with_logger
import AlgebraicPetri: PropertyLabelledReactionNet, LabelledPetriNet, AbstractPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import CSV
import DataFrames: DataFrame

include("./SciMLOperations.jl")
import .SciMLOperations: simulate, calibrate
include("./Queuing.jl"); import .Queuing: MQLogger
include("./Settings.jl"); import .Settings: settings

export sciml_operations, conversions_for_valid_inputs

"""
Sim runs that can be created using the `/runs/sciml/{operation}` endpoint.    
"""
sciml_operations = Dict{Symbol,Function}(
    :simulate => simulate,
    :calibrate => calibrate,
    # TODO(five): Add `ensemble` operation
)

# TODO(five): Move to separate module??
_coerce_dataset(val::String) = CSV.read(IOBuffer(val), DataFrame)
_coerce_dataset(val::DataFrame) = val

"""
Inputs converted from payload to arguments expanded in operations.    
"""
conversions_for_valid_inputs = Dict{Symbol,Function}(
    :model => (val) -> parse_json_acset(PropertyLabelledReactionNet{Number, Number, Dict}, val), # hack for mira
    :tspan => (val) -> Tuple{Float64,Float64}(val),
    :params => (val) -> Dict{String,Float64}(val),
    :initials => (val) -> Dict{String,Float64}(val),
    :dataset => _coerce_dataset,
    :feature_mappings => (val) -> Dict{String, String}(val),
    :timesteps_column => (val) -> String(val)
)

"""
Return an operation wrapped with necessary handlers    
"""
function use_operation(name::Symbol) #NOTE: Should we move `prepare_output` here?
    selected_operation = sciml_operations[name]
    operation = if settings["SHOULD_LOG"]
                    function logged(args...; kwargs...)
                        with_logger(MQLogger()) do
                            selected_operation(args...; kwargs...)
                        end
                    end
                    logged
                else
                    selected_operation
                end
                
    # NOTE: This runs inside the job so we can't use it to validate on request ATM
    function coerced_operation(arglist::Dict{Symbol, Any}) 
        # TODO(five): Fail properly on extra params
        fixed_args = Dict(
           name => conversions_for_valid_inputs[name](value)
           for (name, value) in arglist 
        )
        operation(;fixed_args...)
    end
    coerced_operation
end

end # module SciMLInterface
