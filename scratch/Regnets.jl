using RegNets, RegNets.ASKEMRegNets
using Catlab.Graphs, Catlab.CategoricalAlgebra, Catlab.Graphics
using JSON3, HTTP, DifferentialEquations
using ModelingToolkit

#model_json = JSON3.read(HTTP.get("https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/regnet/examples/lotka_volterra.json").body)
sg = HTTP.get(
  "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/regnet/examples/lotka_volterra.json"
).body |> String |> parse_askem_model
#lotka_volterra = parse_askem_model(model_json)


function vectorfield(sg::AbstractSignedGraph)
  (u, p, t) -> [p[:vrate][i]*u[i] + sum((sg[e,:sign] ? 1 : -1)*p[:erate][e]*u[i]u[sg[e, :src]] for e in incident(sg, i, :tgt); init=0.0) for i in 1:nv(sg)]
end


function regnet_to_MTK(sg::AbstractSignedGraph)
  t = only(@variables t)
  D = Differential(t)
  
  vertex_names = sg[:vname]
  vertex_vars  = [only(@variables $s) for s in vertex_names]
  vertex_funcs = [only(@variables $s(t)) for s in vertex_names]
  
  e_rate_names = [Symbol("erate_$name") for name in sg[:ename]]
  e_rate_vars = [only(@parameters $x) for x in e_rate_names]
  
  v_rate_names = [Symbol("vrate_$name") for name in vertex_names]
  v_rate_vars = [only(@parameters $x) for x in v_rate_names]
  
  v_rates = sg[:vrate]
  e_rates = sg[:erate]
  
  rate_params_list = [v_rate_vars .=> v_rates; e_rate_vars .=> e_rates]
  
  rate_params = Dict(rate_params_list)
  
  initial_vals = sg[:initial]
  initial_val_map = Dict(vertex_funcs .=> initial_vals)
  
  eqs = [D(vertex_funcs[i]) ~ v_rate_vars[i]*vertex_funcs[i] + sum((sg[e,:sign] ? 1 : -1) * e_rate_vars[e] * vertex_funcs[i] * vertex_funcs[sg[e,:src]] for e in incident(sg,i,:tgt); init = 0.0) for i in 1:nv(sg)]
  
  sys = ODESystem(eqs,t, name = :system, initial_val_map)
end

regnet_to_MTK(sg)


t = only(@variables t)
D = Differential(t)

vertex_names = sg[:vname]
vertex_vars  = [only(@variables $s) for s in vertex_names]
vertex_funcs = [only(@variables $s(t)) for s in vertex_names]

e_rate_names = [Symbol("erate_$name") for name in sg[:ename]]
e_rate_vars = [only(@parameters $x) for x in e_rate_names]

v_rate_names = [Symbol("vrate_$name") for name in vertex_names]
v_rate_vars = [only(@parameters $x) for x in v_rate_names]

v_rates = sg[:vrate]
e_rates = sg[:erate]

rate_params_vars = [v_rate_vars ; e_rate_vars]
rate_params_list = [v_rate_vars .=> v_rates; e_rate_vars .=> e_rates]

#rate_params = Dict(rate_params_list)

initial_vals = sg[:initial]
initial_val_map = vertex_funcs .=> initial_vals

eqs = [D(vertex_funcs[i]) ~ v_rate_vars[i]*vertex_funcs[i] + sum((sg[e,:sign] ? 1 : -1) * e_rate_vars[e] * vertex_funcs[i] * vertex_funcs[sg[e,:src]] for e in incident(sg,i,:tgt); init = 0.0) for i in 1:nv(sg)]

sys = ODESystem(eqs,t,vertex_funcs, rate_params_vars,name = :system, defaults = [rate_params_list ; initial_val_map])
prob = ODEProblem(sys, initial_val_map,(0,100), rate_params)

plot(solve(prob,Tsit5()))

#prob = ODEProblem(
#  vectorfield(lotka_volterra), # generate the vectorfield
#  lotka_volterra[:initial],    # get the initial concentrations
#  (0.0, 100.0),                # set the time period
#  lotka_volterra,              # pass in model which contains the rate parameters
#  alg=Tsit5()
#)

vectorfield(lotka_volterra)