"""
Handle logging    
"""
module Failures

export Failure

struct Failure <: Exception
    reason::String
end

Base.showerror(io::IO, exception::Failure) = print(io, "Task completed without error but failed. Reason: ", exception.reason)
    
end # module Failures
