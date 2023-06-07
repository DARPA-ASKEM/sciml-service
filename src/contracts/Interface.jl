"""
SciML Operations interface for the simulation service
"""
module Interface

import CSV

include("./ProblemInputs.jl"); import .ProblemInputs: conversions_for_valid_inputs
include("./SystemInputs.jl"); import .SystemInputs: Context
include("../operations/Operations.jl"); import .Operations
include("../Settings.jl"); import .Settings: settings

export get_operation, conversions_for_valid_inputs, Context

"""
Sim runs that can be created using the `/runs/sciml/{operation}` endpoint.    
"""
function get_operation(raw_operation)
    operation = Symbol(raw_operation)
    if in(operation, names(Operations; all=false, imported=true))
        return getfield(Operations, operation)
    else
        return nothing
    end
end

"""
Return an operation wrapped with necessary handlers    
"""
function use_operation(context::Context)
    operation = get_operation(context.operation)

    method = collect(methods(operation))[1]
    inputs = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), method.slot_syms)[2:last]
    
                
    # NOTE: This runs inside the job so we can't use it to validate on request ATM
    function coerced_operation(arglist::Dict{Symbol, Any}) 
        # TODO(five): Fail properly on extra params
        fixed_args = Dict(
           name => conversions_for_valid_inputs[name](arglist[name])
           for name in inputs 
        )
        operation(;fixed_args..., context=context)
    end
end

end # module Interface
