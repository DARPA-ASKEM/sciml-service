
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

    structural_simplify(ODESystem(eqs, t, allfuncs, paramvars; defaults = [statefuncs .=> initial_vals; sym_defs], name=Symbol(amr.name)))
end

# priors
function amr_get(amr::JSON3.Object, sys::ODESystem, ::Val{:priors})
    @info "amr_get priors"
    paramlist = EasyModelAnalysis.ModelingToolkit.parameters(sys)
    namelist = nameof.(paramlist)

    map(amr.semantics.ode.parameters) do p
        @assert p.distribution.type === "StandardUniform1"
        dist = EasyModelAnalysis.Distributions.Uniform(p.distribution.parameters.minimum, p.distribution.parameters.maximum)
        paramlist[findfirst(x->x==Symbol(p.id),namelist)] => dist
    end
end

# data
function amr_get(df::DataFrame, sys::ODESystem, ::Val{:data})
    @info "parse dataset into calibrate format"
    statelist = states(sys)
    statenames = string.(statelist)
    statenames = [replace(nm, "(t)" => "") for nm in statenames]
    tvals = df[:,"timestamp"]

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
    function IntermediateResults(id::String; every=Dates.Second(5))
        new(typemin(Dates.DateTime), every, id)
    end
end
function (o::IntermediateResults)(integrator)
    if o.last_callback + o.every ≤ Dates.now()
        o.last_callback = Dates.now()
        (; iter, t, u, uprev) = integrator
        publish_to_rabbitmq(; iter=iter, time=t, params=u, abserr=norm(u - uprev), id=o.id,
            retcode=SciMLBase.check_error(integrator))
    end
    EasyModelAnalysis.DifferentialEquations.u_modified!(integrator, false)
end

get_callback(o::OperationRequest) = DiscreteCallback((args...) -> true, IntermediateResults(o.id), 
                                                      save_positions = (false,false))


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

function solve(op::Simulate; kw...)
    # joshday: What does providing `u0 = []` do?  Don't we know what u0 is from AMR?
    prob = ODEProblem(op.sys, [], op.timespan)
    sol = solve(prob; progress = true, progress_steps = 1, saveat=1, kw...)
    @info "Timesteps returned are: $(sol.t)"
    dataframe_with_observables(sol)
end

#-----------------------------------------------------------------------------# Calibrate
struct Calibrate <: Operation
    sys::ODESystem
    timespan::Tuple{Float64, Float64}
    priors::Vector{Pair{SymbolicUtils.BasicSymbolic{Real}, Uniform{Float64}}}
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

function solve(o::Calibrate; callback)
    prob = ODEProblem(o.sys, [], o.timespan)
    statenames = [states(o.sys);getproperty.(observed(o.sys), :lhs)]

    if o.calibrate_method == "bayesian"
        p_posterior = EasyModelAnalysis.bayesian_datafit(prob, o.priors, o.data;
                                                        nchains = 2,
                                                        niter = 100,
                                                        mcmcensemble = SimulationService.EasyModelAnalysis.Turing.MCMCSerial())

        pvalues = last.(p_posterior)

        probs = [EasyModelAnalysis.remake(prob, p = Pair.(first.(p_posterior), getindex.(pvalues,i))) for i in 1:length(p_posterior[1][2])]
        enprob = EasyModelAnalysis.EnsembleProblem(probs)
        ensol = solve(enprob, saveat = 1)
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
            fit = EasyModelAnalysis.datafit(prob, init_params, o.data)
        else
            init_params = Pair.(EasyModelAnalysis.ModelingToolkit.Num.(first.(o.priors)), tuple.(minimum.(last.(o.priors)), maximum.(last.(o.priors))))
            fit = EasyModelAnalysis.global_datafit(prob, init_params, o.data)
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
struct Ensemble <: Operation
    sys::Vector{ODESystem}
    priors::Vector{Pair{Num,Any}} # Any = Distribution
    train_datas::Any
    ensem_datas::Any
    t_forecast::Vector{Float64}
    quantiles::Vector{Float64}
end

function Ensemble(o::OperationRequest)
    sys = amr_get.(o.models, ODESystem)
end

function solve(o::Ensemble; callback)
    probs = [ODEProblem(s, [], o.timespan) for s in sys]
    ps = [[β => Uniform(0.01, 10.0), γ => Uniform(0.01, 10.0)] for i in 1:3]
    datas = [data_train,data_train,data_train]
    enprobs = bayesian_ensemble(probs, ps, datas)
    ensem_weights = ensemble_weights(sol, data_ensem)

    forecast_probs = [remake(enprobs.prob[i]; tspan = (t_train[1],t_forecast[end])) for i in 1:length(enprobs.prob)]
    fit_enprob = EnsembleProblem(forecast_probs)
    sol = solve(fit_enprob; saveat = o.t_forecast);

    soldata = DataFrame([sol.t;Matrix(sol[names])'])

    # Requires https://github.com/SciML/SciMLBase.jl/pull/467
    # weighted_ensem = WeightedEnsembleSolution(sol, ensem_weights; quantiles = o.quantiles)
    # df = DataFrame(weighted_ensem)
    # df, soldata
end
#-----------------------------------------------------------------------------# All operations
# :simulate => Simulate, etc.
const operations2type = Dict(Symbol(lowercase(string(T.name.name))) => T for T in subtypes(Operation))
