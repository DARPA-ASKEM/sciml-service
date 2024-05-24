using RegNets
using Catlab
using JSON3
using Catlab.Graphics
using Catlab.Programs
using Catlab.WiringDiagrams
using Catlab.CategoricalAlgebra
using ModelingToolkit
using HTTP


@present SchASKEMRegNet <: SchRateSignedGraph begin
  C::AttrType
  Name::AttrType
  initial::Attr(V,C)
  vname::Attr(V,Name)
  ename::Attr(E,Name)

  v_rate_name::Attr(V,Name)
  e_rate_name::Attr(E,Name)
end


@abstract_acset_type AbstractASKEMRegNet <: AbstractSignedGraph
@acset_type ASKEMRegNetUntyped(SchASKEMRegNet, index=[:src, :tgt]) <: AbstractASKEMRegNet
const ASKEMRegNet = ASKEMRegNetUntyped{Bool,Float64,Float64,Symbol}

function parse_askem_model(input::AbstractDict, ::Type{ASKEMRegNetUntyped})
    regnet = ASKEMRegNet()
    param_vals = Dict(p["id"]=>p["value"] for p in input["model"]["parameters"])

    # `x::String` could be either a parameter (e.g. "alpha") or a number (e.g. "0.9")
    resolve_val(x) = x
    resolve_val(x::String) = haskey(param_vals, x) ? param_vals[x] : parse(Float64, x)

    vertice_idxs = Dict(vertice["id"]=> add_part!(regnet, :V;
      vname=Symbol(vertice["id"]),
      vrate=haskey(vertice, "rate_constant") ? (vertice["sign"] ? 1 : -1) * resolve_val(vertice["rate_constant"]) : 0,
      initial=haskey(vertice, "initial") ? resolve_val(vertice["initial"]) : 0,
      v_rate_name = Symbol(vertice["rate_constant"])
    ) for vertice in input["model"]["vertices"])

    for edge in input["model"]["edges"]
      rate = 0
      if haskey(edge, "properties") && haskey(edge["properties"], "rate_constant")
        rate = resolve_val(edge["properties"]["rate_constant"])
        # rate >= 0 || error("Edge rates must be strictly positive")
      end
      add_part!(regnet, :E; src=vertice_idxs[edge["source"]],
                            tgt=vertice_idxs[edge["target"]],
                            sign=edge["sign"],
                            ename=Symbol(edge["id"]),
                            erate=rate,
                            e_rate_name = Symbol(edge.properties["rate_constant"]))
    end

    regnet
end

parse_askem_model(input::AbstractString) = parse_askem_model(JSON3.parse(input))

function read_askem_model(fname::AbstractString)
  parse_askem_model(JSON3.parsefile(fname))
end

function ASKEM_ACSet_to_MTK(sg::ASKEMRegNetUntyped)
    t = only(@variables t)
    D = Differential(t)

    vertex_names = sg[:vname]
    vertex_vars  = [only(@variables $s) for s in vertex_names]
    vertex_funcs = [only(@variables $s(t)) for s in vertex_names]

    e_rate_names = [Symbol("$name") for name in sg[:e_rate_name]]
    e_rate_vars = [only(@parameters $x) for x in e_rate_names]

    v_rate_names = [Symbol("$name") for name in sg[:v_rate_name]]
    v_rate_vars = [only(@parameters $x) for x in v_rate_names]

    v_rates = sg[:vrate]
    e_rates = sg[:erate]

    rate_params_list = [v_rate_vars .=> v_rates; e_rate_vars .=> e_rates]

    rate_params = Dict(rate_params_list)

    all_params = [e_rate_vars ; v_rate_vars]
    initial_vals = sg[:initial]
    initial_val_map = Dict(vertex_funcs .=> initial_vals)

    defaults = merge(rate_params, initial_val_map)

    eqs = [D(vertex_funcs[i]) ~ v_rate_vars[i]*vertex_funcs[i] + sum((sg[e,:sign] ? 1 : -1) * e_rate_vars[e] * vertex_funcs[i] * vertex_funcs[sg[e,:src]] for e in incident(sg,i,:tgt); init = 0.0) for i in 1:nv(sg)]

    sys = structural_simplify(ODESystem(eqs, t, vertex_funcs, all_params; name = :system, defaults))
end
