using SimulationService
using Test

SimulationService.ENABLE_TDS = true

json = @config(model_config_id = "2b08c681-ee0e-4ad1-81d5-e0e3e203ffbe", timespan.start=0.0, timespan.end=100.0)
body = JSON3.write(json)
res = HTTP.post("$url/simulate",  ["Content-Type" => "application/json"]; body)
