# This only works if you are using the TDS instance set up by Brandon Rose.
# Talk to Brandon or Josh Day for information.

# Docs: $TDS_URL/#/Simulation/simulation_delete_simulations__simulation_id__delete

using SimulationService: get_model, get_dataset, create, update, complete, get_json, solve,
    DataServiceModel, OperationRequest, TDS_URL, TDS_RETRIES, ENABLE_TDS

using HTTP, JSON3, DataFrames, EasyConfig, Test

SimulationService.ENABLE_TDS = true

#-----------------------------------------------------------------------------# Check that TDS is running
get_simulations() = get_json("$TDS_URL/simulations", Vector{Config})
simulations = get_simulations()
for sim in simulations
    res = HTTP.delete("$TDS_URL/simulations/$(sim.id)")
    @test res.status == 200
end
sleep(2)
simulations = get_simulations()
@test isempty(simulations)

#-----------------------------------------------------------------------------# get_model ✓
model_config_id = "2b08c681-ee0e-4ad1-81d5-e0e3e203ffbe"
obj = get_model(model_config_id)
@test !isempty(obj)

#-----------------------------------------------------------------------------# get_dataset ✓
datasets = get_json("$TDS_URL/datasets", Vector{Config})

data_obj = Config(
    id = datasets[1].id,
    name = datasets[1].name,
    filename = datasets[1].file_names[1]
)

get_dataset(data_obj)

#-----------------------------------------------------------------------------# create ✓
# mock request to SimulationService
payload = @config(model_config_id=model_config_id, timespan.start=1, timespan.end=100, engine="sciml")
body = JSON3.write(payload)
req = HTTP.Request("POST", "", ["Content-Type" => "application/json"], body)
o = OperationRequest(req, "simulate")
id = o.id

res = create(o)  # Create TDS representation of model
@test JSON3.read(res.body).id == id

# Check that simulation with `id` now exists in TDS
sleep(2)
@test HTTP.get("$TDS_URL/simulations/$id").status == 200

#-----------------------------------------------------------------------------# DataServiceModel ✓
m = DataServiceModel(id)
@test m.id == id

#-----------------------------------------------------------------------------# update ✓
res = update(o; status = "running")
@test res.status == 200
@test JSON3.read(res.body).id == id
sleep(1)
@test get_json("$TDS_URL/simulations/$id").status == "running"

#-----------------------------------------------------------------------------# complete ✓
@test_throws "solve(" complete(o)

solve(o)

res = complete(o)
@test res.status == 200
@test JSON3.read(res.body).id == id
@test get_json("$TDS_URL/simulations/$id").status == "complete"


#-----------------------------------------------------------------------------# ALL TOGETHER NOW ✓
SimulationService.operation(req, "simulate")

#-----------------------------------------------------------------------------# with server ✓
start!()

url = SimulationService.server_url[]

sleep(3) # Give server a chance to start

@testset "/" begin
    res = HTTP.get(url)
    @test res.status == 200
    @test JSON3.read(res.body).status == "ok"
end


#-----------------------------------------------------------------------------# simulate ✓
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
@test res.status == 201
id = JSON3.read(res.body).simulation_id

for i in 1:20
    tds_status = get_json("$TDS_URL/simulations/$id").status
    @info "simulate status: $tds_status"
    if tds_status == "complete"
        @test true
        break
    elseif tds_status == "error"
        @test false
        break
    end
    sleep(0.5)
end





#-----------------------------------------------------------------------------# calibrate
data_id = "e81fede5-2645-4c83-90b1-46a916764b1f"

body = JSON3.write(@config(
    model_config_id = model_config_id,
    dataset.id = data_id,
    dataset.name = "Example Dataset",
    dataset.filename = "dataset.csv",
    engine = "sciml",
    timespan.start=1,
    timespan.end=100
))

res = HTTP.post("$url/calibrate", ["Content-Type" => "application/json"]; body)
@test res.status == 201
id = JSON3.read(res.body).simulation_id

for i in 1:20
    tds_status = get_json("$TDS_URL/simulations/$id").status
    @info "simulate status: $tds_status"
    if tds_status == "complete"
        @test true
        break
    elseif tds_status == "error"
        @test false
        break
    end
    sleep(0.5)
end



#-----------------------------------------------------------------------------# Done!
stop!()
@info "Done!"
