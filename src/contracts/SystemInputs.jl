"""
System provided information that is made available to operations    
"""
module SystemInputs

export Context

struct Context
    job_id::Int64
    interactivity_hook::Function
    operation::Symbol
    raw_args
    function Context(job_id::Int64, interactivity_hook::Function, operation::Symbol, raw_args)
        new(job_id, interactivity_hook, operation, deepcopy(raw_args))
    end
end 

function Base.iterate(context::Context, state=nothing)
    if isnothing(state)
        state = Set(fieldnames(Context))
    end
    unused = intersect(Set(fieldnames(Context)), state)
    if isempty(unused)
        return nothing
    end
    chosen_field = pop!(unused)
    (chosen_field=>getfield(context, chosen_field), unused)
end

end # module SystemInputs