using SimulationService, DifferentialEquations, ModelingToolkit, AlgebraicPetri
using SimulationService.SciMLInterface.SciMLOperations
using MathML, JSON3, Symbolics, Catlab.CategoricalAlgebra
fn = joinpath(@__DIR__, "../examples/request-simulate-sir.json")
j = JSON3.read(read(fn))

original_json = JSON3.read(j.model)
askem_petri = SciMLOperations.json_to_petri(original_json)
model = original_json.model
pn = askem_petri.petri

id_sts_to_val = map(x->x.id=>MathML.parse_str(x.initial.expression_mathml), original_json.model.states)
id_ps_to_val = map(x->x.id=>MathML.parse_str(x.properties.rate.expression_mathml), original_json.model.transitions)

sts = first.(id_sts_to_val)

syms = [last.(id_sts_to_val); last.(id_ps_to_val)]

id_ps = map(x->x.id=>x.value, model.parameters)
ps_syms = [only(@variables $x) for x in Symbol.(first.(id_ps))]
psd = Dict(id_ps)

sym_defs = ps_syms .=> last.(id_ps)


union(Symbolics.get_variables.(syms)...)

# SimulationService.SciMLInterface.SciMLOperations._symbolize_args(id_ps, last.(id_to_val))
sys = ODESystem(pn)

# u0 values
u0_defs = states(sys) .=> map(x->substitute(x, sym_defs), last.(id_sts_to_val))
idc = [u0_defs;sym_defs]
ODESystem(pn;defaults=idc)


pn2= read_json_acset(LabelledPetriNet, "/Users/anand/.julia/dev/ASKEM_Evaluation_Staging/docs/src/Scenario3/sirhd_vax_age11.json")
pn2= read_json_acset(LabelledPetriNet, "/Users/anand/.julia/dev/ASKEM_Evaluation_Staging/docs/src/Scenario3/sirhd_vax.json")


pn2 = read_json_acset(LabelledPetriNet, "/Users/anand/.julia/dev/ASKEM_Evaluation_Staging/docs/src/Scenario3/sir.json")
sys2 = ODESystem(pn2)
display(AlgebraicPetri.Graph(pn2))

# using Catlab, Catlab.Theories
# using Catlab.CategoricalAlgebra
# using Catlab.Graphs
# using Catlab.Graphics

# draw(g; kw...) = to_graphviz(g; node_labels=true, edge_labels=true, kw...)
# draw(f::ACSetTransformation; kw...) =
#   to_graphviz(f; node_labels=true, edge_labels=true, draw_codom=false, kw...)

# to_graphviz(SchGraph)

# e = @acset Graph begin
#     V = 2
#     E = 1
#     src = [1]
#     tgt = [2]
# end

# draw(e)