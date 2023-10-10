
#-----------------------------------------------------------------------------# amr_get
# Things that extract info from AMR JSON
# The AMR is the `model` field of an OperationRequest


# Get `ModelingToolkit.ODESystem` from AMR
function amr_get(amr::JSON3.Object, ::Type{ODESystem})
    @info "amr_get ODESystem"
    model = amr.model
    ode = amr.semantics.ode

    t = only(@variables t)
    D = Differential(t)

    statenames = [Symbol(s.id) for s in model.states]
    statevars  = [only(@variables $s) for s in statenames]
    statefuncs = [only(@variables $s(t)) for s in statenames]
    obsnames   = [Symbol(o.id) for o in ode.observables]
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

    for (o, ofunc) in zip(ode.observables, obsfuncs)
        expr = substitute(MathML.parse_str(o.expression_mathml), subst)
        push!(eqs, ofunc ~ expr)
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
            paramlist[findfirst(x->x==Symbol(p.id),namelist)] => dist
        end
    end
    priors = filter(!isnothing, priors)
end

# data
function amr_get(df::DataFrame, sys::ODESystem, ::Val{:data})
    @info "parse dataset into calibrate format"
    statelist = states(sys)
    statenames = string.(statelist)
    statenames = [replace(nm, "(t)" => "") for nm in statenames]

    tvals = df[:, "timestamp"]

    map(statelist, statenames) do s,n
        s => (tvals,df[:,n])
    end
end

#--------------------------------------------------------------------# IntermediateResults callback
# Publish intermediate results to RabbitMQ with at least `every` seconds inbetween callbacks
mutable struct IntermediateResults
    last_callback::Dates.DateTime  # Track the last time the callback was called
    every::Dates.TimePeriod  # Callback frequency e.g. `Dates.Second(5)`
    id::String
    every_iteration::Bool # If the results are reported for every step of intergration
    function IntermediateResults(id::String; every=Dates.Second(5), every_iteration = false)
        new(typemin(Dates.DateTime), every, id, every_iteration)
    end
end

function (o::IntermediateResults)(integrator)
    if o.every_iteration == true
        (; iter, f, t, u, p) = integrator

        state_dict = Dict(states(f.sys) .=> u)
        param_dict = Dict(parameters(f.sys) .=> p)

        publish_to_rabbitmq(; iter=iter, time=t, state=state_dict, params = param_dict, id=o.id,
            retcode=SciMLBase.check_error(integrator))
    elseif o.last_callback + o.every ≤ Dates.now() && every_iteration == false
        o.last_callback = Dates.now()
        (; iter, f, t, u, p) = integrator

        state_dict = Dict(states(f.sys) .=> u)
        param_dict = Dict(parameters(f.sys) .=> p)

        publish_to_rabbitmq(; iter=iter, time=t, state=state_dict, params = param_dict, id=o.id,
            retcode=SciMLBase.check_error(integrator))
    end
    EasyModelAnalysis.DifferentialEquations.u_modified!(integrator, false)
end

#get_callback(o::OperationRequest) = DiscreteCallback((args...) -> true, IntermediateResults(o.id),
#                                                      save_positions = (false,false))

#----------------------------------------------------------------------# dataframe_with_observables
function dataframe_with_observables(sol::ODESolution)
    sys = sol.prob.f.sys
    names = [states(sys); getproperty.(observed(sys), :lhs)]
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

function solve(op::Simulate; callback)
    prob = ODEProblem(op.sys, [], op.timespan)
    sol = solve(prob; progress = true, progress_steps = 1, saveat=1, callback = callback)
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
        :num_iterations in extrakeys && (num_iterations = o.obj.extra.num_iterations)
        :calibrate_method in extrakeys && (calibrate_method = o.obj.extra.calibrate_method)
    end
    Calibrate(sys, o.timespan, priors, data, num_chains, num_iterations, calibrate_method, ode_method)
end

# Jadon Clugston: maybe we want separate callbacks for the optimizer and the ode solve?
function solve(o::Calibrate; callback)
    prob = ODEProblem(o.sys, [], o.timespan)
    statenames = [states(o.sys);getproperty.(observed(o.sys), :lhs)]

    # todo: fix this when ensembles are fixed
    if o.calibrate_method == "bayesian"
        p_posterior = EasyModelAnalysis.bayesian_datafit(prob, o.priors, o.data;
                                                        nchains = 2,
                                                        niter = 100,
                                                        mcmcensemble = SimulationService.EasyModelAnalysis.Turing.MCMCSerial())

        pvalues = last.(p_posterior)

        probs = [EasyModelAnalysis.remake(prob, p = Pair.(first.(p_posterior), getindex.(pvalues,i))) for i in 1:length(p_posterior[1][2])]
        enprob = EasyModelAnalysis.EnsembleProblem(probs)
        ensol = solve(enprob; saveat = 1, solve_kws = (callback = callback, kwargshandle = :KeywordArgSilent))
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
    elseif o.calibrate_method == "local" || o.calibrate_method == "global"
        if o.calibrate_method == "local"
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), Statistics.mean.(last.(o.priors)))
            fit = EasyModelAnalysis.datafit(prob, init_params, o.data, solve_kws = (callback = callback,))
        else
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), tuple.(minimum.(last.(o.priors)), maximum.(last.(o.priors))))
            fit = EasyModelAnalysis.global_datafit(prob, init_params, o.data, solve_kws = (callback = callback, kwargshandle = :KeywordArgSilent))
        end

        newprob = EasyModelAnalysis.DifferentialEquations.remake(prob, p=fit)
        sol = EasyModelAnalysis.DifferentialEquations.solve(newprob; saveat = 1)#, callback = callback)
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
# joshday: What is different between simulate and calibrate for ensemble?

struct Ensemble{T<:Operation} <: Operation
    model_ids::Vector{String}
    operations::Vector{T}
    weights::Vector{Float64}
    sol_mappings::Vector{JSON3.Object}
end

function Ensemble{T}(o::OperationRequest) where {T}
    model_ids = map(x -> x.id, o.obj.model_configs)
    weights = map(x -> x.weight, o.obj.model_configs)
    sol_mappings = map(x -> x.solution_mappings, o.obj.model_configs)
    operations = map(o.models) do model
        temp = OperationRequest()
        temp.df = o.df
        temp.timespan = o.timespan
        temp.model = model
        temp.obj = o.obj
        T(temp)
    end
    Ensemble{T}(model_ids, operations, weights, sol_mappings)
end

function solve(o::Ensemble{Simulate}; callback)
    systems = [sim.sys for sim in o.operations]
    probs = ODEProblem.(systems, Ref([]), Ref(o.operations[1].timespan))
    enprob = EMA.EnsembleProblem(probs)
    sol = solve(enprob; saveat = 1, callback);
    weights = [0.2, 0.5, 0.3]
    data = [x => vec(sum(stack(o.weights .* sol[:,x]), dims = 2)) for x in error("What goes here?")]
end


function solve(o::Ensemble{Calibrate}; callback)
    probs = [ODEProblem(cal.sys, [], o.timespan) for cal in o.operations]
    error("TODO")


    # probs = [ODEProblem(s, [], o.timespan) for s in sys]
    # ps = [[β => Uniform(0.01, 10.0), γ => Uniform(0.01, 10.0)] for i in 1:3]
    # datas = [data_train,data_train,data_train]
    # enprobs = EMA.bayesian_ensemble(probs, ps, datas)
    # ensem_weights = EMA.ensemble_weights(sol, data_ensem)

    # forecast_probs = [EMA.remake(enprobs.prob[i]; tspan = (t_train[1],t_forecast[end])) for i in 1:length(enprobs.prob)]
    # fit_enprob = EMA.EnsembleProblem(forecast_probs)
    # sol = solve(fit_enprob; saveat = o.t_forecast, callback);

    # soldata = DataFrame([sol.t; Matrix(sol[names])'])

    # Requires https://github.com/SciML/SciMLBase.jl/pull/467
    # weighted_ensem = WeightedEnsembleSolution(sol, ensem_weights; quantiles = o.quantiles)
    # df = DataFrame(weighted_ensem)
    # df, soldata
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

function get_callback(o::OperationRequest)
    optype = route2operation_type[o.route]
    get_callback(o,optype)
end

# callback for Calibrate requests
function get_callback(o::OperationRequest, ::Type{Calibrate})
    function (p,lossval,ode_sol)  
        param_dict = Dict(parameters(ode_sol.prob.f.sys) .=> ode_sol.prob.p)
        state_dict = Dict([state => ode_sol[state] for state in states(ode_sol.prob.f.sys)])
        publish_to_rabbitmq(; loss = lossval, sol_data = state_dict, params = param_dict, id=o.id)
    end
end

# callback for Simulate requests
function get_callback(o::OperationRequest, ::Type{Simulate})
    DiscreteCallback((args...) -> true, IntermediateResults(o.id,every_iteration = true),
                                                    save_positions = (false,false))
end


const route2operation_type = Dict(
    "simulate" => Simulate,
    "calibrate" => Calibrate,
    "ensemble-simulate" => Ensemble{Simulate},
    "ensemble-calibrate" => Ensemble{Calibrate}
)
