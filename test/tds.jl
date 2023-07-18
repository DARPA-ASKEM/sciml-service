# This only works if you are using the TDS instance set up by Brandon Rose.
# Talk to Brandon or Josh Day for information.

# Docs: $(TDS_URL[])/#/Simulation/simulation_delete_simulations__simulation_id__delete

using SimulationService
using SimulationService: get_model, get_dataset, create, update, complete, get_json, solve,
    DataServiceModel, OperationRequest, TDS_URL

using HTTP, JSON3, DataFrames, Dates, Test

SimulationService.ENABLE_TDS[] = true
SimulationService.PORT[] = 8081


#-----------------------------------------------------------------------------# start from scratch
get_simulations() = get_json("$(TDS_URL[])/simulations")
simulations = get_simulations()
for sim in simulations
    res = HTTP.delete("$(TDS_URL[])/simulations/$(sim.id)")
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
datasets = get_json("$(TDS_URL[])/datasets")

data_obj = JSON3.read(JSON3.write((;
    id = datasets[1].id,
    name = datasets[1].name,
    filename = datasets[1].file_names[1],
    mappings = (; Ailing = "A")
)))

get_dataset(data_obj)

#-----------------------------------------------------------------------------# create ✓
payload = (; model_config_id, timespan = (; start=1, var"end"=100), engine="sciml")
body = JSON3.write(payload)
req = HTTP.Request("POST", "", ["Content-Type" => "application/json"], body)
o = OperationRequest(req, "simulate")
id = o.id

res = create(o)  # Create TDS representation of model
@test JSON3.read(res.body).id == id

# Check that simulation with `id` now exists in TDS
sleep(2)
@test HTTP.get("$(TDS_URL[])/simulations/$id").status == 200

#-----------------------------------------------------------------------------# DataServiceModel ✓
m = DataServiceModel(id)
@test m.id == id

#-----------------------------------------------------------------------------# update ✓
res = update(o; status = "running")
@test res.status == 200
@test JSON3.read(res.body).id == id
sleep(1)
@test get_json("$(TDS_URL[])/simulations/$id").status == "running"

#-----------------------------------------------------------------------------# complete ✓
@test_throws "solve(" complete(o)

solve(o)

res = complete(o)
@test res.status == 200
@test JSON3.read(res.body).id == id
@test get_json("$(TDS_URL[])/simulations/$id").status == "complete"


#-----------------------------------------------------------------------------# ALL TOGETHER NOW ✓
SimulationService.operation(req, "simulate")

start!()
url = SimulationService.server_url[]
sleep(3) # Give server a chance to start

#-----------------------------------------------------------------------------# simulate ✓
res = HTTP.post("$url/simulate", ["Content-Type" => "application/json"]; body)
@test res.status == 201
id = JSON3.read(res.body).simulation_id
sleep(2)

t = now()
while true
    tds_status = get_json("$(TDS_URL[])/simulations/$id").status
    @info "simulate status ($(round(now() - t, Dates.Second))): $tds_status"
    if tds_status == "complete"
        @test true
        break
    elseif tds_status == "error"
        @test false
        break
    end
    sleep(5)
end

@test get_json("$(TDS_URL[])/simulations/$id").status == "complete"





#-----------------------------------------------------------------------------# calibrate X
data_id = "e81fede5-2645-4c83-90b1-46a916764b1f"

body = JSON3.write((;
    model_config_id,
    dataset = (id = data_id, name = "Example Dataset", filename = "dataset.csv"),
    engine = "sciml",
    timespan = (start=1, var"end"=100)
))

res = HTTP.post("$url/calibrate", ["Content-Type" => "application/json"]; body)
@test res.status == 201
id = JSON3.read(res.body).simulation_id
sleep(2)

t = now()
while true
    tds_status = get_json("$(TDS_URL[])/simulations/$id").status
    @info "calibrate status ($(round(now() - t, Dates.Second))): $tds_status"
    if tds_status == "complete"
        @test true
        break
    elseif tds_status == "error"
        @test false
        break
    end
    sleep(5)
end

@test get_json("$(TDS_URL[])/simulations/$id").status == "complete"



#-----------------------------------------------------------------------------# Done!
stop!()
@info "Done!"
