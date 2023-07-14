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
@test obj.id == model_config_id

#-----------------------------------------------------------------------------# get_dataset ???
# TODO

#-----------------------------------------------------------------------------# create ✓
# mock request to SimulationService
payload = @config(model_config_id=model_config_id, timespan.start=1, timespan.end=100, engine="sciml")
req = HTTP.Request("POST", "", ["Content-Type" => "application/json"], JSON3.write(payload))
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

#-----------------------------------------------------------------------------# complete ✓
@test_throws "solve(" complete(o)

o.result = DataFrame(fake=1:10, results=randn(10))

res = complete(o)
@test res.status == 200
@test JSON3.read(res.body).id == id


#-----------------------------------------------------------------------------# ALL TOGETHER NOW ???
SimulationService.operation(req, "simulate")

#-----------------------------------------------------------------------------# with server ???
start!()

url = SimulationService.server_url[]

sleep(3) # Give server a chance to start

@testset "/" begin
    res = HTTP.get(url)
    @test res.status == 200
    @test JSON3.read(res.body).status == "ok"
end


res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
@test res.status == 201
id = JSON3.read(res.body).simulation_id
done_or_failed = false
while !done_or_failed
    st = JSON3.read(HTTP.get("$url/status/$id").body).status
    st in ["queued", "complete", "running"] ? @test(true) : @test(false)
    done_or_failed = st in ["complete", "error"]
    sleep(1)
end
@test SimulationService.last_operation[].result isa DataFrame
