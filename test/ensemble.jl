
dfc = CSV.read("cases.csv", DataFrame)
dfd = CSV.read("deaths.csv", DataFrame)
dfh = CSV.read("hosp.csv", DataFrame)
function calibration_data(dfc, dfd, dfh; use_hosp=false)

    us_ = dfc[dfc.location.=="US", :]
    usd_ = dfd[dfd.location.=="US", :]
    ush_ = dfh[dfh.location.=="US", :]

    rename!(us_, :value => :cases)
    rename!(usd_, :value => :deaths)
    rename!(ush_, :value => :hosp)

    if use_hosp
        d_ = innerjoin(us_, usd_, ush_, on=:date, makeunique=true)
        d = d_[:, [:date, :cases, :deaths, :hosp]]
    else
        d_ = innerjoin(us_, usd_, on=:date, makeunique=true)
        d = d_[:, [:date, :cases, :deaths]]
    end

    us_ = d
    sort!(us_, :date)
    us = deepcopy(us_)
    # us[!, :unix] = datetime2unix.(DateTime.(us.date))
    insertcols!(us, 1, :unix => datetime2unix.(DateTime.(us.date)))
    # us
end
covidhub = calibration_data(dfc, dfh, dfd, use_hosp=true)
fitdata = covidhub[1:20, [:t, :cases, :deaths, :hosp]]
jdata = objecttable(fitdata)
write("fitdata.json", jdata)

# todo global_datafit
sir_fn = "/Users/anand/.julia/dev/simulation-scheduler/examples/sir.json"
sird_fn = "/Users/anand/.julia/dev/simulation-scheduler/examples/sird.json"
sirh_fn = "/Users/anand/.julia/dev/simulation-scheduler/examples/sirh.json"
sirhd_fn = "/Users/anand/.julia/dev/simulation-scheduler/examples/sirhd.json"
pns = sir, sird, sirh, sirhd = [read_json_acset(T, fn) for fn in (sir_fn, sird_fn, sirh_fn, sirhd_fn)]

syss = sys1, sys2, sys3, sys4 = ODESystem.(pns)

strat_fn = "/Users/anand/.julia/dev/ASKEM_Evaluation_Staging/docs/src/Scenario3/sirhd_renew_vax.json"
sp = read_json_acset(LabelledPetriNet, strat_fn)
@which ODESystem(sp)
st_sys = ODESystem(sp)
st_sts = states(st_sys)
st_ps = parameters(st_sys)

# this section demonstrates the difficulty of quickly building observed maps from stratified petrinets

strat_st_vecs = eval.(Meta.parse.(String.(Symbolics.getname.(st_sts))))
vsts = st_sts[findall(==("V"), last.(strat_st_vecs))]
usts = st_sts[findall(==("U"), last.(strat_st_vecs))]
ists = st_sts[findall(==("I"), first.(strat_st_vecs))]

sidarthe = ODESystem(petri)
@unpack Susceptible, Infected, Diagnosed, Ailing, Recognized, Threatened, Healed, Extinct = sidarthe
S, I, D, A, R, T, H, E = Susceptible, Infected, Diagnosed, Ailing, Recognized, Threatened,
Healed, Extinct
Hospitalizations = Recognized + Threatened
Cases = Diagnosed + Recognized + Threatened
cases_data = map(sum, eachrow(df[:, ["Diagnosed(t)", "Recognized(t)", "Threatened(t)"]]))
hospitalizations_data = map(sum, eachrow(df[:, ["Recognized(t)", "Threatened(t)"]]))
df[!, "Cases(t)"] = cases_data
df[!, "Hospitalizations(t)"] = hospitalizations_data
df[!, "Extinct"] = hospitalizations_data
sym_data = [=> df[:, "Susceptible(t)"]]


sns = snames.(pns)
all_sns = map(x -> string.(x), sns)
tns = tnames.(pns)
all_tns = map(x -> string.(x), tns)
to_init(x) = x .=> rand(length(x))
all_inits = to_init.(all_sns)
all_tspan = (0.0, 100.0)
all_params = to_init.(all_tns)

mapping = Dict([
    "I" => "cases",
    "H" => "hosp",
    "D" => "deaths"
])

jd = (;)
sirhd_j = generate_json_acset(sirhd)
ensemble_nt = (; models=[(; petri=sirhd_j, params=Dict(all_params[4]), initials=Dict(all_inits[4]), tspan=all_tspan, mapping=mapping)], data=namedtuple(JSON3.read(jdata)))
ensemble_json = JSON3.write(ensemble_nt)
write(_log("ensemble.json"), ensemble_json)
b = JSON3.read(read(_log("ensemble.json")))
models = b.models
m = b.models[1]
data = b.data
mp = collect(Dict(m.mapping))
map_to_data(mp, d) = string.(first.(mp)) .=> map(x -> Float64.(collect(d[Symbol(x)])), last.(mp))
# build_cali_nt
mpn = JSON3.write(m.petri)

# write_json_acset("sirhd.json", m.petri)
parse_json_acset(TAny, mpn)
function ensemble_calibrate(; models, data)
    # m = models[1]
    fits = []
    for m in models
        data_ = map_to_data(mp, data)
        
        params_ = collect(m.params)
        paramsd = Dict(string.(first.(params_)) .=> last.(params_))

        initials_ = collect(m.initials)
        initialsd = Dict(string.(first.(initials_)) .=> last.(initials_))
        t = data.t
        nt = (; petri=parse_json_acset(TAny, mpn), params=paramsd, initials=initialsd, t=Float64.(collect(t)), data=Dict(data_))
        push!(fits, Scheduler.SciMLInterface._datafit(; nt...))
    end
    fits
end