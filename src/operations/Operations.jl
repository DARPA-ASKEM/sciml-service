"""
SciML Operation definitions
"""
module Operations

import AlgebraicPetri: LabelledPetriNet, AbstractPetriNet
import DataFrames: DataFrame, names
import DifferentialEquations: solve, DiscreteCallback
import ModelingToolkit: remake, ODESystem, ODEProblem
import Symbolics: Num, getname, @variables, substitute
import SymbolicIndexingInterface: states, parameters
import EasyModelAnalysis
import SciMLBase

using LinearAlgebra: norm
using Dates: Dates, DateTime, now

# import MathML

# include("./Utils.jl"); import .Utils: to_prob, unzip, symbolize_args, select_data

# NOTE: Operations exposed to the rest of the Simulation Service
export simulate, calibrate, ensemble


#-----------------------------------------------------------------------------# utils

# Transform model representation into a SciML ODEProblem
function to_prob(sys, tspan)
    ODEProblem(sys, [], tspan, saveat=1)
end

# Separate keys and values
unzip(d::Dict) = (collect(keys(d)), collect(values(d)))

# Unzip a collection of pairs
unzip(ps) = first.(ps), last.(ps)


# Transform list of args into Symbolics variables
function symbolize_args(incoming_values, sys_vars)
    pairs = collect(incoming_values)
    ks, values = unzip(pairs)
    symbols = Symbol.(ks)
    vars_as_symbols = getname.(sys_vars)
    symbols_to_vars = Dict(vars_as_symbols .=> sys_vars)
    Dict(
        [
            symbols_to_vars[vars_as_symbols[findfirst(x -> x == symbol, vars_as_symbols)]]
            for symbol in symbols
        ] .=> values
    )
end


# Generate data and timestep list from a dataframe
function select_data(df::DataFrame)
    data = Dict(
        key => df[!, key]
        for key in names(df) if key != "timestep"
    )
    df[!, "timestep"], data
end

#-----------------------------------------------------------------------------# IntermediateReulsts callback
# Return information about current state of the solver at regular intervals
mutable struct IntermediateResults
    last_callback::DateTime
    every::Dates.TimePeriod
    context  # ::Union{Nothing, Context}
end
IntermediateResults(context; every=Dates.Second(5)) = IntermediateResults(typemin(DateTime), every, context)

# TODO: ensure that this is called at the end of the solve
function (o::IntermediateResults)(integrator)
    if o.last_callback + o.every ≤ now()
        o.last_callback = now()
        d = Dict(
            :iter => integrator.iter,
            :time => integrator.t,
            :params => integrator.u,
            :abserr => norm(integrator.u - integrator.uprev),
            :retcode => Symbol(SciMLBase.check_error(integrator)),
        )
        if isnothing(o.context)
            @info "IntermediateResults: $(NamedTuple(d))"
        else
            d[:job_id] = context.job_id
            context.interactivity_hook(d)
        end
    end
end

#-----------------------------------------------------------------------------# simulate
function simulate(; model::ODESystem, timespan::Tuple{Float64,Float64}=(0.0, 100.0), context=nothing)
    prob = to_prob(model, timespan)
    res = IntermediateResults(context)
    callback = DiscreteCallback((args...) -> true, res)
    sol = solve(prob; progress = true, progress_steps = 1, callback)
    DataFrame(sol)
end

#-----------------------------------------------------------------------------# calibrate
function calibrate(; model, dataset::DataFrame, context=nothing)
    timesteps, data = select_data(dataset)
    prob = to_prob(model, extrema(timesteps))
    p = Vector{Pair{Num, Float64}}([Num(param) => model.defaults[param] for param in parameters(model)])
    @show p
    data = symbolize_args(data, states(model))
    fitp = EasyModelAnalysis.datafit(prob, p, timesteps, data)
    @info fitp
    # DataFrame(fitp)
    fitp
end

#-----------------------------------------------------------------------------# ensemble
function ensemble(; models::AbstractArray{AbstractPetriNet}, timespan::Tuple{Float64, Float64} = (0.0, 100.0), context=nothing)
    throw("ENSEMBLE IS NOT YET IMPLEMENTED")
end


# joshday: what is this function?
"long running functions like global_datafit and sensitivity wrappers will need to be refactored to share callback info incrementally"
function _global_datafit(; model::LabelledPetriNet,
    parameter_bounds::Dict{String,Tuple{Float64,Float64}},
    params::Dict{String,Float64},
    initials::Dict{String,Float64},
    t::Vector{Number},
    data::Dict{String,Vector{Float64}}
)::DataFrame
    ks, vs = unzip(parameter_bounds)
    @assert all(issorted.(vs))
    prob = to_prob(model, params, initials, extrema(t))
    sys = prob.f.sys
    p = symbolize_args(params, parameters(sys)) # this ends up being a second call to symbolize_args 🤷
    fitp = global_datafit(prob, collect(p), t, data)
    DataFrame(fitp)
end

end # module Operations
