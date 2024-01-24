using Catlab
using Catlab.CategoricalAlgebra
using Distributions
using MLStyle

using Catlab.Graphics
using Catlab.Programs
using Catlab.WiringDiagrams
using HTTP
using JSON3
using MathML

@present SchASKEMStockFlow(FreeSchema) begin

 # Objects:
    Flow::Ob
    Stock::Ob
    Link::Ob
    Parameter::Ob
    Auxiliary::Ob
    Observable::Ob
    Header::Ob
# Morphisms:
    u::Hom(Flow, Stock)
    d::Hom(Flow, Stock)
    s::Hom(Link, Stock)
    t::Hom(Link, Flow)

# Attributes:
    Name::AttrType
    FuncFlow::AttrType
    id::AttrType
    Value::AttrType
    Distribution::AttrType
    Initial::AttrType
    
    f_name::Attr(Flow, Name)
    ϕf::Attr(Flow, FuncFlow)
    f_id::Attr(Flow, id)

    s_name::Attr(Stock, Name)
    s_id::Attr(Stock, id)
    s_initial::Attr(Stock,Initial)
    s_expr::Attr(Stock,FuncFlow)

    p_name::Attr(Parameter, Name)
    p_id::Attr(Parameter, id)
    p_expr::Attr(Parameter, FuncFlow)
    p_value::Attr(Parameter, Value)
    p_distribution::Attr(Parameter,Distribution)
    
   
    
    aux_id::Attr(Auxiliary, id)
    aux_name::Attr(Auxiliary, Name)
    aux_expr::Attr(Auxiliary, FuncFlow)
    aux_value::Attr(Auxiliary, Value)
 
    obs_id::Attr(Observable, id)
    obs_name::Attr(Observable, Name)
    obs_expr::Attr(Observable, FuncFlow)

    head_name::Attr(Header, Name)
    
end

@abstract_acset_type AbstractASKEMStockFlow

@acset_type ASKEMStockFlowType(SchASKEMStockFlow, index = [:u, :d, :s, :t]) <: AbstractASKEMStockFlow

const ASKEMStockFlow = ASKEMStockFlowType{Symbol, Union{Symbolics.Num, Number}, Symbol, Number, Union{Distribution, Nothing}, Number}

function parse_askem_model(input::AbstractDict, ::Type{ASKEMStockFlow})
    d = ASKEMStockFlow()

    # add name
    add_part!(d,:Header,head_name = Symbol(input[:header][:name]))

    for param in input[:semantics][:ode][:parameters]
        # want to exclude 
        id = Symbol(param[:id])
        name = Symbol(param[:name])
        value = param[:value]
        expr = only((@parameters $id))
        if haskey(param,:distribution)
            distribution = @match param[:distribution][:type] begin
                "StandardUniform1"  => StandardUniform
                "StandardNormal"    => StandardNormal
                "Uniform"           => Uniform(param[:distribution][:parameters][:minimum], param[:distribution][:parameters][:maximum])
                "Uniform1"          => Uniform(param[:distribution][:parameters][:minimum], param[:distribution][:parameters][:maximum])
                "Normal"            => Normal(param[:distribution][:parameters][:mu], param[:distribution][:parameters][:var])
                "PointMass"         => PointMass(param[:distribution][:parameters][:value])
            end
        else 
            distribution = nothing
        end

        add_part!(d,:Parameter, p_id = id, p_name = name, p_value = value, p_expr = expr, p_distribution = distribution)
    end

    for aux in input[:model][:auxiliaries]
        id = Symbol(aux[:id])
        name = Symbol(aux[:name])
        expr = MathML.parse_str(aux[:expression_mathml])
        param_dict = Dict([subpart(d,i,:p_expr) => subpart(d,i,:p_value) for i in 1:nparts(d,:Parameter)])
        value = ModelingToolkit.substitute(expr, param_dict)
        add_part!(d,:Auxiliary, aux_id = id, aux_name = name, aux_expr = expr, aux_value = value)
    end

    for obs in input[:semantics][:ode][:observables]
        id = Symbol(obs[:id])
        name = Symbol(obs[:name])
        expr = MathML.parse_str(obs[:expression_mathml])
        add_part!(d,:Observable,obs_id = id, obs_name = name, obs_expr = expr)
    end

    for stock in input[:model][:stocks]
        name = Symbol(stock[:name])
        id = Symbol(stock[:id])
        initial_expr = MathML.parse_str(only(filter(x -> Symbol(x[:target]) == id, input[:semantics][:ode][:initials]))[:expression_mathml])

        param_dict = Dict([subpart(d,i,:p_expr) => subpart(d,i,:p_value) for i in 1:nparts(d,:Parameter)])
        
        new_initial = ModelingToolkit.substitute(initial_expr, param_dict)
        s_expr = only(@variables $id)
        add_part!(d,:Stock, s_name = Symbol(name), s_id = Symbol(id),s_initial = new_initial,s_expr = s_expr)
    end

    # remove the "initial condition" parameters after they've been used
    for initial in input[:semantics][:ode][:initials]
        for i in 1:nparts(d,:Parameter)
            if subpart(d,i,:p_id) == Symbol(initial[:expression])
                rem_part!(d,:Parameter,i)   
            end
        end
    end

    for flow in input[:model][:flows]
        name = Symbol(flow[:name])
        id = Symbol(flow[:id])
        upstream_stock_str = Symbol(flow[:upstream_stock])
        upstream_stock = only(filter(i -> subpart(d,i,:s_id) == upstream_stock_str, 1:nparts(d,:Stock))) 

        downstream_stock_str = Symbol(flow[:downstream_stock])
        downstream_stock = only(filter(i -> subpart(d,i,:s_id) == downstream_stock_str, 1:nparts(d,:Stock)))
        flow_expr = MathML.parse_str(flow[:rate_expression_mathml])

        add_part!(d,:Flow, f_name = name, f_id = id, u = upstream_stock, d = downstream_stock, ϕf = flow_expr )
    end
    d
end

# return inflows of stock index s
inflows(p::ASKEMStockFlow,s) = incident(p,s,:d)
# return outflows of stock index s
outflows(p::ASKEMStockFlow,s) = incident(p,s,:u)

function ASKEM_ACSet_to_MTK(sf::ASKEMStockFlow)
    t = only(@variables t)
    D = Differential(t)
    # do substitutions on Flow equations to get them in terms of the original parameters
    paramvars = [subpart(sf,i,:p_expr) for i in 1:nparts(sf,:Parameter)]
    param_dict = Dict(paramvars .=> paramvars)

    aux_flows = [subpart(sf,i,:ϕf) for i in 1:nparts(sf,:Flow)]
    vars_symbols = [Symbol(subpart(sf,i,:aux_id)) for i in 1:nparts(sf,:Auxiliary)]
    vars_symbolics = [only(@parameters $var) for var in vars_symbols] #ugh the aux_dict line is giving me trouble so I'll do this
    aux_dict = Dict([vars_symbolics[i] => subpart(sf,i,:aux_expr) for i in 1:nparts(sf,:Auxiliary)])
    
    stock_names = [subpart(sf,n,:s_id) for n in 1:nparts(sf,:Stock)]
    stock_funcs = [only(@variables $s(t)) for s in stock_names]

    stock_dict = Dict([subpart(sf,i,:s_expr) => stock_funcs[i] for i in 1:nparts(sf,:Stock)])

    flow_exprs = [ModelingToolkit.substitute(flow_expr, aux_dict) for flow_expr in aux_flows]
    flow_exprs = [ModelingToolkit.substitute(flow_expr, param_dict) for flow_expr in flow_exprs]
    flow_exprs = [ModelingToolkit.substitute(expr, stock_dict) for expr in flow_exprs]

    if nparts(sf,:Observable) > 0
        obs_names = [subpart(sf,i,:obs_name) for i in 1:nparts(sf,:Observable)]
        obs_names_funcs = [only(@variables $name(t)) for name in obs_names]
        obs_expr = [ModelingToolkit.substitute(subpart(sf,i,:obs_expr), stock_dict) for i in 1:nparts(sf,:Observable) if !in(subpart(sf,i,:obs_name),stock_names)]
        obs_eqs = [func ~ expr for (func,expr) in zip(obs_names_funcs, obs_expr)]
    end

    
    #paramvars = [only(@parameters $param) for param in param_exprs]

    inflow_list =  [reduce(+, [flow_exprs[i] for i in inflows(sf,n) if !isempty(inflows(sf,n))], init = 0.0) for n in 1:nparts(sf,:Stock)]
    outflow_list = [reduce(+, [flow_exprs[i] for i in outflows(sf,n) if !isempty(outflows(sf,n))], init = 0.0) for n in 1:nparts(sf,:Stock)]

    eqs = [D(stock_funcs[n]) ~ inflow_list[n] - outflow_list[n] for n in 1:nparts(sf,:Stock)]

    if nparts(sf,:Observable) > 0
        eqs = [eqs ; obs_eqs]
    end

    inits = Dict(stock_funcs .=> [subpart(sf,n,:s_initial) for n in 1:nparts(sf,:Stock)])
    paramvals = Dict(paramvars .=> [subpart(sf,n,:p_value) for n in 1:nparts(sf,:Parameter)])
    defaults = merge(inits,paramvals)
    name = subpart(sf,1,:head_name)

    sys = ODESystem(eqs, t, stock_funcs, paramvars; name = name, defaults = defaults)
    
    sys = structural_simplify(sys, check_consistency = false)
end
