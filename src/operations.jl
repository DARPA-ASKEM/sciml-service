
#-----------------------------------------------------------------------------# amr_get
# Things that extract info from AMR JSON
# The AMR is the `model` field of an OperationRequest


# Get `ModelingToolkit.ODESystem` from AMR

function amr_get(amr::JSON3.Object,::Type{ODESystem})
        schema_url = amr.header.schema
        if contains(schema_url,"petrinet_schema")
            return amr_get_petrinet(amr)
        elseif contains(schema_url, "stockflow_schema")
            return amr_get_stockflow(amr)
        elseif  contains(schema_url,"regnet_schema")
            return amr_get_regnet(amr)
        end
end

function amr_get_stockflow(amr::JSON3.Object)
    model = parse_askem_model(amr, ASKEMStockFlow)
    ASKEM_ACSet_to_MTK(model)
end

function amr_get_regnet(amr::JSON3.Object)
    model = parse_askem_model(amr, ASKEMRegNetUntyped)
    ASKEM_ACSet_to_MTK(model)
end

function amr_get_petrinet(amr::JSON3.Object)
    @info "amr_get ODESystem"
    model = amr.model
    ode = amr.semantics.ode

    t = only(@variables t)
    D = Differential(t)

    statenames = [Symbol(s.id) for s in model.states]
    statevars  = [only(@variables $s) for s in statenames]
    statefuncs = [only(@variables $s(t)) for s in statenames]
    obsnames   = []
    if haskey(ode, "observables")
        obsnames = [Symbol(o.id) for o in ode.observables]
    end
    obsvars    = [only(@variables $o) for o in obsnames]
    obsfuncs   = [only(@variables $o(t)) for o in obsnames]
    allvars    = [statevars; obsvars]
    allfuncs   = [statefuncs; obsfuncs]

    # get parameter values and state initial values
    paramnames = [Symbol(x.id) for x in ode.parameters]
    paramvars = [only(@parameters $x) for x in paramnames]
    paramvals = [x.value for x in ode.parameters]
    sym_defs = paramvars .=> paramvals
    initial_exprs = [MathML.parse_str(x.expression_mathml) for x in ode.initials]
    initial_vals = map(x -> substitute(x, sym_defs), initial_exprs)

    # build equations from transitions and rate expressions
    rates = Dict(Symbol(x.target) => MathML.parse_str(x.expression_mathml) for x in ode.rates)
    eqs = Dict(s => Num(0) for s in statenames)
    for tr in model.transitions
        ratelaw = rates[Symbol(tr.id)]
        for s in tr.input
            s = Symbol(s)
            eqs[s] = eqs[s] - ratelaw
        end
        for s in tr.output
            s = Symbol(s)
            eqs[s] = eqs[s] + ratelaw
        end
    end

    subst = merge!(Dict(allvars .=> allfuncs), Dict(paramvars .=> paramvars))
    eqs = [D(statef) ~ substitute(eqs[state], subst) for (state, statef) in (statenames .=> statefuncs)]

    if haskey(ode, "observables")
        for (o, ofunc) in zip(ode.observables, obsfuncs)
            expr = substitute(MathML.parse_str(o.expression_mathml), subst)
            push!(eqs, ofunc ~ expr)
        end
    end

    defaults = [statefuncs .=> initial_vals; sym_defs]
    name = Symbol(amr.header.name)
    sys = structural_simplify(ODESystem(eqs, t, allfuncs, paramvars; defaults, name))
    @info "amr_get(amr, ODESystem) --> $sys"

    sys
end

# priors
function amr_get(amr::JSON3.Object, sys::ODESystem, ::Val{:priors})
    @info "amr_get priors"
    paramlist = EasyModelAnalysis.ModelingToolkit.parameters(sys)
    namelist = nameof.(paramlist)

    # this is silly, but some of the models don't have an amr.semantics.ode
    if haskey(amr, :semantics)
        priors = map(amr.semantics.ode.parameters) do p
            if haskey(p, :distribution)
                # Assumption: only fit parameters which have a distribution / bounds
                if p.distribution.type != "StandardUniform1" && p.distribution.type != "Uniform1"
                    @info "Invalid distribution type! Distribution type was $(p.distribution.type)"
                end

                minval = if p.distribution.parameters.minimum isa Number
                    p.distribution.parameters.minimum
                elseif p.distribution.parameters.minimum isa AbstractString
                    @info "String in distribution minimum: $(p.distribution.parameters.minimum)"
                    parse(Float64, p.distribution.parameters.minimum)
                end

                maxval = if p.distribution.parameters.maximum isa Number
                    p.distribution.parameters.maximum
                elseif p.distribution.parameters.maximum isa AbstractString
                    @info "String in distribution maximum: $(p.distribution.parameters.maximum)"
                    parse(Float64, p.distribution.parameters.maximum)
                end

                dist = EasyModelAnalysis.Distributions.Uniform(minval, maxval)

                param = findfirst(x->x==Symbol(p.id),namelist)
                
                if !isnothing(param)
                    paramlist[param] => dist
                end
            end
        end
    else
        initial_names = [vertex[:initial] for vertex in amr[:model][:vertices]]
        
        priors = map(amr.model.parameters) do p
            if !in(p[:id], initial_names)
                if haskey(p, :distribution)
                    # Assumption: only fit parameters which have a distribution / bounds
                    if p.distribution.type != "StandardUniform1" && p.distribution.type != "Uniform1"
                        @info "Invalid distribution type! Distribution type was $(p.distribution.type)"
                    end

                    minval = if p.distribution.parameters.minimum isa Number
                        p.distribution.parameters.minimum
                    elseif p.distribution.parameters.minimum isa AbstractString
                        @info "String in distribution minimum: $(p.distribution.parameters.minimum)"
                        parse(Float64, p.distribution.parameters.minimum)
                    end

                    maxval = if p.distribution.parameters.maximum isa Number
                        p.distribution.parameters.maximum
                    elseif p.distribution.parameters.maximum isa AbstractString
                        @info "String in distribution maximum: $(p.distribution.parameters.maximum)"
                        parse(Float64, p.distribution.parameters.maximum)
                    end

                    dist = EasyModelAnalysis.Distributions.Uniform(minval, maxval)
                    paramlist[findfirst(x->x==Symbol(p.id),namelist)] => dist
                end
            end
        end
    end
    priors = filter(!isnothing, priors)
end

# data
function amr_get(df::DataFrame, sys::ODESystem, ::Val{:data})
    @info "parse dataset into calibrate format"
    statelist = unknowns(sys)
    statenames = string.(statelist)
    statenames = [replace(nm, "(t)" => "") for nm in statenames]
                                    
    tvals = df[:, "timestamp"]

    [s => (tvals,df[:,n]) for (s,n) in zip(statelist,statenames) if n ∈ names(df)]
end

#--------------------------------------------------------------------# IntermediateResults callback
# Publish intermediate results to RabbitMQ with at least `every` iterations in between callbacks
mutable struct IntermediateResults
    last_callback::Int # Track the last iteration the callback was called
    every::Int  # Callback frequency
    id::String
    iter::Int # Track how many iterations of the calibration have happened
    function IntermediateResults(id::String; every = 10)
        new(0, every, id, 0)
    end
end
# Intermediate results functor for calibrate
function (o::IntermediateResults)(state,loss_val, ode_sol, ts)
    if o.last_callback + o.every == o.iter
        o.last_callback = o.iter
        param_dict = Dict(parameters(ode_sol.prob.f.sys) .=> state.u)
        state_dict = Dict([state => ode_sol(first(ts))[state] for state in unknowns(ode_sol.prob.f.sys)])
        publish_to_rabbitmq(; iter = o.iter, loss = loss_val, sol_data = state_dict, timesteps = first(ts), params = param_dict, id=o.id)
    end
    o.iter = o.iter + 1
    return false
end
#----------------------------------------------------------------------# dataframe_with_observables
function dataframe_with_observables(sol::ODESolution)
    sys = sol.prob.f.sys
    names = [unknowns(sys); getproperty.(observed(sys), :lhs)]
    cols = ["timestamp" => sol.t; [string(n) => sol[n] for n in names]]
    DataFrame(cols)
end


#-----------------------------------------------------------------------------# Operations
abstract type Operation end

#-----------------------------------------------------------------------------# simulate
struct Simulate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
end

function Simulate(o::OperationRequest)
    sys = amr_get(o.model, ODESystem)
    Simulate(sys, o.timespan)
end

function get_callback(o::OperationRequest, ::Type{Simulate})
    DiscreteCallback((args...) -> true, IntermediateResults(o.id,every = 10))
end

function (o::IntermediateResults)(integrator)
    (; iter, f, t, u, p, sol) = integrator
    t_end = sol.prob.tspan[2]
    percent = round((t/t_end)*100.0, digits = 2)
    if o.last_callback + o.every == iter
        o.last_callback = iter
        #state_dict = Dict(states(f.sys) .=> u)
        #param_dict = Dict(parameters(f.sys) .=> p)
        publish_to_rabbitmq(;id=o.id,
            retcode=SciMLBase.check_error(integrator), percent = percent)
    end
    EasyModelAnalysis.DifferentialEquations.u_modified!(integrator, false)
end


# callback for Simulate requests
function solve(op::Simulate; callback)
    prob = ODEProblem(op.sys, [], op.timespan)
    sol = solve(prob; saveat=1, callback = callback)
    @info "Timesteps returned are: $(sol.t)"
    dataframe_with_observables(sol)
end

#-----------------------------------------------------------------------------# Calibrate
struct Calibrate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
    priors::Vector
    data::Any
    num_chains::Int
    num_iterations::Int
    calibrate_method::String
    ode_method::Any
end

# callback for Calibrate requests
function get_callback(o::OperationRequest, ::Type{Calibrate})
    IntermediateResults(o.id,every = 10)
end

function Calibrate(o::OperationRequest)
    sys = amr_get(o.model, ODESystem)
    priors = amr_get(o.model, sys, Val(:priors))
    data = amr_get(o.df, sys, Val(:data))

    num_chains = 4
    num_iterations = 100
    calibrate_method = "global"
    ode_method = nothing

    if :extra in keys(o.obj)
        extrakeys = keys(o.obj.extra)
        :num_chains in extrakeys && (num_chains = o.obj.extra.num_chains)
        :num_iterations in extrakeys && (num_iterations = o.obj.extra.num_iterations) # only for bayesian?
        :calibrate_method in extrakeys && (calibrate_method = o.obj.extra.calibrate_method)
    end
    Calibrate(sys, o.timespan, priors, data, num_chains, num_iterations, calibrate_method, ode_method)
end

function solve(o::Calibrate; callback)
    prob = ODEProblem(o.sys, [], o.timespan)
    statenames = [unknowns(o.sys);getproperty.(observed(o.sys), :lhs)]

    # bayesian datafit 
    if o.calibrate_method == "bayesian"
        p_posterior = EasyModelAnalysis.bayesian_datafit(prob, o.priors, o.data;
                                                        nchains = o.num_chains,
                                                        niter = o.num_iterations,
                                                        mcmcensemble = SimulationService.EasyModelAnalysis.Turing.MCMCSerial())

        pvalues = last.(p_posterior)

        probs = [EasyModelAnalysis.remake(prob, p = Pair.(first.(p_posterior), getindex.(pvalues,i))) for i in 1:length(p_posterior[1][2])]
        enprob = EasyModelAnalysis.EnsembleProblem(probs)
        ensol = solve(enprob; saveat = 1)
        outs = map(1:length(probs)) do i
            mats = stack(ensol[i][statenames])'
            headers = string.("ensemble",i,"_", statenames)
            mats, headers
        end
        dfsim = DataFrame(hcat(ensol[1].t, reduce(hcat, first.(outs))), :auto)
        rename!(dfsim, ["timestamp";reduce(vcat, last.(outs))])

        dfparam = DataFrame(last.(p_posterior), :auto)
        rename!(dfparam, Symbol.(first.(p_posterior)))

        dfsim, dfparam
    
    # local / global datafit
    elseif o.calibrate_method == "local" || o.calibrate_method == "global"
        if o.calibrate_method == "local"
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), Statistics.mean.(last.(o.priors)))
            fit = EasyModelAnalysis.datafit(prob, init_params, o.data, loss = sciml_service_l2loss, solve_kws = (callback = callback,))
        else
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), tuple.(minimum.(last.(o.priors)), maximum.(last.(o.priors))))
            fit = EasyModelAnalysis.global_datafit(prob, init_params, o.data, loss = sciml_service_l2loss, solve_kws = (callback = callback,))
        end

        newprob = EasyModelAnalysis.DifferentialEquations.remake(prob, p=fit)
        sol = EasyModelAnalysis.DifferentialEquations.solve(newprob; saveat = 1)
        dfsim = DataFrame(hcat(sol.t,stack(sol[statenames])'), :auto)
        rename!(dfsim, ["timestamp";string.(statenames)])

        dfparam = DataFrame(Matrix(last.(fit)'), :auto)
        rename!(dfparam, Symbol.(first.(fit)))

        dfsim, dfparam
    else
        error("$(o.calibrate_method) is not a valid choice of calibration method")
    end
end

#-----------------------------------------------------------------------------# Ensemble
struct EnsembleSimulate <: Operation
    model_ids::Vector{String}
    systems::Dict{String,ODESystem}
    weights::Dict{String,Float64}
    sol_mappings::Dict{String,JSON3.Object}
    timespan::Tuple{Float64, Float64}
end

function EnsembleSimulate(o::OperationRequest)
    model_ids = map(x -> x.id, o.obj.model_configs)
    dict = Dict(model_ids .=> o.models)
    systems = Dict([id => SimulationService.amr_get(dict[id], ODESystem) for id in model_ids])
    weights = Dict(map(x -> x.id => x.weight, o.obj.model_configs))
    sol_mappings = Dict(map(x -> x.id => x.solution_mappings, o.obj.model_configs))
    timespan = o.timespan

    EnsembleSimulate(model_ids,systems,weights,sol_mappings,timespan)
end

struct EnsembleCalibrate <: Operation
    model_ids::Vector{String}
    systems::Dict{String,ODESystem}
    sol_mappings::Dict{String,JSON3.Object}
    timespan::Tuple{Float64, Float64}
    df::DataFrame
end

# need to finish
function EnsembleCalibrate(o::OperationRequest)
    model_ids = map(x -> x.id, o.obj.model_configs)
    dict = Dict(model_ids .=> o.models)
    systems = Dict([id => SimulationService.amr_get(dict[id], ODESystem) for id in model_ids])
    sol_mappings = Dict(map(x -> x.id => x.solution_mappings, o.obj.model_configs))
    timespan = o.timespan
    df = o.df

    EnsembleCalibrate(model_ids,systems,sol_mappings,timespan,df)
end

function get_callback(o::OperationRequest, ::Type{EnsembleSimulate})
    nothing
end

function get_callback(o::OperationRequest, ::Type{EnsembleCalibrate})
    nothing
end

# Solves multiple ODEs, performs a weighted sum
# of the solutions.
function solve(o::EnsembleSimulate; callback)
    systems = o.systems
    model_ids = o.model_ids

    probs = Dict([id => ODEProblem(systems[id], [], o.timespan) for id in model_ids])
    
    sols = Dict([id => solve(probs[id]; saveat = 1, callback) for id in model_ids])

    # Associate the name in sol_mappings with the right state/observable
    map_to_state = Dict([id => Dict([k => sols[id][getproperty(systems[id],Symbol(v))] for (k,v) in o.sol_mappings[id]]) for id in model_ids])
    
    weights = o.weights

    # the keys for all solution mappings should be the same
    sol_mappings_keys = keys(o.sol_mappings[o.model_ids[1]])

    data = [k => reduce(+ , [weights[id] .* map_to_state[id][k] for id in o.model_ids]) for k in sol_mappings_keys]

    DataFrame(:timestamp => sols[model_ids[1]].t, data...)
end

function solve(o::EnsembleCalibrate; callback)
    systems = o.systems
    model_ids = o.model_ids
    df = o.df

    probs = Dict([id => ODEProblem(systems[id], [], o.timespan) for id in model_ids])
    
    enprob = EasyModelAnalysis.EnsembleProblem([probs[id] for id in model_ids])

    data = o.df 

    data_pairs = [Symbol(name) => data[:,name] for name in names(data)]
    t_stamps = filter(x -> x[1] == :timestamp, data_pairs)
    data_pairs = filter(x -> x[1] != :timestamp, data_pairs)
    sol_mappings_list = [o.sol_mappings[id] for id in model_ids]
    sol = solve(enprob; saveat = t_stamps[1][2], callback);
    weights  = SimulationService.ensemble_weights(sol,data_pairs,sol_mappings_list)
    DataFrame(model_ids .=> weights)
end

# struct Ensemble <: Operation
#     sys::Vector{ODESystem}
#     priors::Vector{Pair{Num,Any}} # Any = Distribution
#     train_datas::Any
#     ensem_datas::Any
#     t_forecast::Vector{Float64}
#     quantiles::Vector{Float64}
# end

# function Ensemble(o::OperationRequest)
#     sys = amr_get.(o.models, ODESystem)
# end

# function solve(o::Ensemble; callback)
#     EMA = EasyModelAnalysis
#     probs = [ODEProblem(s, [], o.timespan) for s in sys]
#     ps = [[β => Uniform(0.01, 10.0), γ => Uniform(0.01, 10.0)] for i in 1:3]
#     datas = [data_train,data_train,data_train]
#     enprobs = EMA.bayesian_ensemble(probs, ps, datas)
#     ensem_weights = EMA.ensemble_weights(sol, data_ensem)

#     forecast_probs = [EMA.remake(enprobs.prob[i]; tspan = (t_train[1],t_forecast[end])) for i in 1:length(enprobs.prob)]
#     fit_enprob = EMA.EnsembleProblem(forecast_probs)
#     sol = solve(fit_enprob; saveat = o.t_forecast, callback);

#     soldata = DataFrame([sol.t; Matrix(sol[names])'])

#     # Requires https://github.com/SciML/SciMLBase.jl/pull/467
#     # weighted_ensem = WeightedEnsembleSolution(sol, ensem_weights; quantiles = o.quantiles)
#     # df = DataFrame(weighted_ensem)
#     # df, soldata
# end

#-----------------------------------------------------------------------------# All operations
# :simulate => Simulate, etc.

const route2operation_type = Dict(
    "simulate" => Simulate,
    "calibrate" => Calibrate,
    "ensemble-simulate" => EnsembleSimulate,
    "ensemble-calibrate" => EnsembleCalibrate
)

# modified from EasyModelAnalysis.jl
function sciml_service_l2loss(pvals, (prob, pkeys, data)::Tuple{Vararg{Any, 3}})
    p = Pair.(pkeys, pvals)
    ts = first.(last.(data))
    lastt = maximum(last.(ts))
    timeseries = last.(last.(data))
    datakeys = first.(data)

    prob = DifferentialEquations.remake(prob, tspan = (prob.tspan[1], lastt), p = p)
    sol = solve(prob)
    tot_loss = 0.0
    for i in 1:length(ts)
        tot_loss += sum((sol(ts[i]; idxs = datakeys[i]) .- timeseries[i]) .^ 2)
    end
    return tot_loss, sol, ts
end

# assumes data is given in the form column_label => data, need sol_mappings to be of form column_label => observable
# modified from EasyModelAnalysis.jl
function ensemble_weights(sol::SciMLBase.EnsembleSolution, data_ensem, sol_mappings_list)
    col = first.(data_ensem)
    predictions = reduce(vcat, reduce(hcat,[sol[i][Symbol(sol_mappings_list[i][s])] for i in 1:length(sol)]) for s in col)
    data = reduce(vcat, [data_ensem[i][2] isa Tuple ? data_ensem[i][2][2] : data_ensem[i][2] for i in 1:length(data_ensem)])
    weights = predictions \ data 
end
