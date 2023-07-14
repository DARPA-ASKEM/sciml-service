#--------------------------------------------------------------------# IntermediateResults callback
# Publish intermediate results to RabbitMQ with at least `every` seconds inbetween callbacks
mutable struct IntermediateResults
    last_callback::Dates.DateTime  # Track the last time the callback was called
    every::Dates.TimePeriod  # Callback frequency e.g. `Dates.Second(5)`
    id::String
    function IntermediateResults(id::String; every=Dates.Second(5))
        new(typemin(Dates.DateTime), every, id)
    end
end
function (o::IntermediateResults)(integrator)
    if o.last_callback + o.every ≤ Dates.now(UTC)
        o.last_callback = Dates.now(UTC)
        (; iter, t, u, uprev) = integrator
        publish_to_rabbitmq(; iter=iter, time=t, params=u, abserr=norm(u - uprev), id=o.id,
            retcode=SciMLBase.check_error(integrator))
    end
end

get_callback(o::OperationRequest) = DiscreteCallback((args...) -> true, IntermediateResults(o.id))


#-----------------------------------------------------------------------------# Operations
# An Operation requires:
#  1) an Operation(::OperationRequest) constructor
#  2) a solve(::Operation; callback) method
#
# An Operation's fields should be separate from any request-specific things for ease of testing.
abstract type Operation end

#-----------------------------------------------------------------------------# simulate
struct Simulate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
end

Simulate(o::OperationRequest) = Simulate(ode_system_from_amr(o.model), o.timespan)

function dataframe_with_observables(sol::ODESolution)
    sys = sol.prob.f.sys
    names = [states(sys); getproperty.(observed(sys), :lhs)]
    cols = ["timestamp" => sol.t; [string(n) => sol[n] for n in names]]
    DataFrame(cols)
end

function solve(op::Simulate; kw...)
    # joshday: What does providing `u0 = []` do?  Don't we know what u0 is from AMR?
    prob = ODEProblem(op.sys, [], op.timespan, saveat=1)
    sol = solve(prob; progress = true, progress_steps = 1, kw...)
    dataframe_with_observables(sol)
end

#-----------------------------------------------------------------------------# calibrate
struct Calibrate <: Operation
    # TODO
end
Calibrate(o::OperationRequest) = error("TODO")
solve(o::Calibrate; callback) = error("TODO")

#-----------------------------------------------------------------------------# ensemble
struct Ensemble <: Operation
    # TODO
end
Ensemble(o::OperationRequest) = error("TODO")
solve(o::Ensemble; callback) = error("TODO")

# :simulate => Simulate, etc.
const OPERATIONS_LIST = Dict(Symbol(lowercase(string(T.name.name))) => T for T in subtypes(Operation))
