"""
SciML Operations interface for the simulation service
"""
module Interface

import CSV

include("./ProblemInputs.jl"); import .ProblemInputs: conversions_for_valid_inputs
include("./SystemInputs.jl"); import .SystemInputs: Context
include("./Available.jl"); import .Available: available_operations
include("../operations/Operations.jl"); import .Operations
include("../Settings.jl"); import .Settings: settings

export use_operation, available_operations, conversions_for_valid_inputs, Context

"""
Return an operation wrapped with necessary handlers    
"""
function use_operation(context::Context)
    operation = available_operations[string(context.operation)]

    method = collect(methods(operation))[1]
    inputs = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), method.slot_syms)[2:end]
    
                
    # NOTE: This runs inside the job so we can't use it to validate on request ATM
    function coerced_operation(arglist::Dict{Symbol, Any}) 
        # TODO(five): Fail properly on extra params
        fixed_args = Dict(
           name => conversions_for_valid_inputs[name](arglist[name])
           for name in inputs if name != :context
        )
        operation(;fixed_args..., context=context)
    end
end

end # module Interface
