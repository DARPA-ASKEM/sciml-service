"""
Converting JSON models to petri
"""
module Converter
# TODO(five): Switch to shared lib that does this in the future
import JSON3 as JSON
import AlgebraicPetri: LabelledPetriNet, PropertyLabelledPetriNet

# TODO(five): Use this struct so default values can be applied
struct ASKEMPetriNet
  petri::PropertyLabelledPetriNet
  json::AbstractDict
end

function to_petri(json)
  original_json = JSON.read(json)
  model = original_json["model"]
  state_props = Dict(Symbol(s["id"]) => s for s in model["states"])
  states = [Symbol(s["id"]) for s in model["states"]]
  transition_props = Dict(Symbol(t["id"]) => t["properties"] for t in model["transitions"])
  transitions = [Symbol(t["id"]) => (Symbol.(t["input"]) => Symbol.(t["output"])) for t in model["transitions"]]

  petri = LabelledPetriNet(states, transitions...)
  #ASKEMPetriNet(PropertyLabelledPetriNet{Dict}(petri, state_props, transition_props), original_json)
  PropertyLabelledPetriNet{Dict}(petri, state_props, transition_props)
end
end # module Converter