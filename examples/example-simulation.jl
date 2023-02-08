using EasyModelAnalysis, LinearAlgebra, CSV
using Catlab, AlgebraicPetri
using Catlab.CategoricalAlgebra
using DataFrames

model = read_json_acset(LabelledPetriNet, "example-model.json")
sys = ODESystem(model)
sys = complete(sys)
@unpack S, I, R, inf, rec = sys
@parameters N = 1
param_sub = [
    inf => inf / N,
]
sys = substitute(sys, param_sub)
defs = ModelingToolkit.defaults(sys)
defs[S] = 990
defs[I] = 10
defs[R] = 0.0
defs[N] = sum(x -> defs[x], (S, I, R))
defs[inf] = 0.5
defs[rec] = 0.25
tspan = (0.0, 40.0)
prob = ODEProblem(sys, [], tspan);
sol = solve(prob);

df = DataFrame(sol)
CSV.write("example-results.csv",df)