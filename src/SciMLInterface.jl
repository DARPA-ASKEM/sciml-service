"""
Shared source of truth for operations and scheduler    
"""
module SciMLInterface

import AlgebraicPetri: LabelledPetriNet
import Catlab.CategoricalAlgebra: parse_json_acset
import Oxygen: serveparallel, serve, resetstate, json, @post, @get
import CSV: write 
import JSON: parse
import DataFrames: DataFrame
import HTTP: Request
import HTTP.Exceptions: StatusError
import JobSchedulers: scheduler_start, set_scheduler, submit!, job_query, result, Job

include("./SciMLOperations.jl"); import .SciMLOperations: forecast

export sciml_operations, conversions_for_valid_inputs

"""
Strip mira metadata out    
"""
function patch_petri(acset)
    if in("S", keys(acset))
        for state in acset["S"]
            delete!(state, "mira_ids")
            delete!(state, "mira_context")
            delete!(state, "mira_initial_value")
        end
    end
    if in("T", keys(acset))
        for state in acset["T"]
            delete!(state, "template_type")
            delete!(state, "parameter_name")
            delete!(state, "parameter_value")
        end
    end
    println(acset)
    acset
end

"""
Sim runs that can be created using the `/runs/sciml/{operation}` endpoint.    
"""
sciml_operations = Dict{Symbol, Function}(
    :forecast=>forecast
    # TODO(five): Add `calibrate` operation
    # TODO(five): Add `ensemble` operation
)

"""
Inputs converted from payload to arguments expanded in operations.    
"""
conversions_for_valid_inputs = Dict{Symbol, Function}(
    :petri => (val)->parse_json_acset(LabelledPetriNet, patch_petri(val)),
    :tspan => (val)->Tuple{Float64, Float64}(val),
    :params => (val)->Dict{String, Float64}(val),
    :initials => (val)->Dict{String, Float64}(val),
)


end # module SciMLInterface
