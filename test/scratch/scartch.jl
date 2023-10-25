using SimulationService, JSON3, EasyModelAnalysis

json_url = "https://raw.githubusercontent.com/DARPA-ASKEM/Model-Representations/main/petrinet/examples/sir.json"
        amr = SimulationService.get_json(json_url)

        obj = (
            model_configs = map(1:4) do i
                (id="model_config_id_$i", weight = i / sum(1:4), solution_mappings = (any_generic = "I", name = "R", s = "S"))
            end,
            models = [amr for _ in 1:4],
            timespan = (start = 0, var"end" = 40),
            engine = "sciml",
            extra = (; num_samples = 40)
        )

        body = JSON3.write(obj)

        # create ensemble-simulte
        o = SimulationService.OperationRequest()
        o.route = "ensemble-simulate"
        o.obj = JSON3.read(JSON3.write(obj))
        o.models = [amr for _ in 1:4]
        o.timespan = (0, 30)
        en = SimulationService.Ensemble{SimulationService.Simulate}(o)

        systems = [sim.sys for sim in en.operations]
        probs = EasyModelAnalysis.ODEProblem.(systems, Ref([]), Ref(en.operations[1].timespan))
        enprob = EasyModelAnalysis.EnsembleProblem(psrobs)
        sol = solve(enprob; saveat = 1, callback = nothing);

        sol_maps = en.sol_mappings[1]
        
        sol_maps = Symbol.(values(sol_maps))
        states(systems[1])
        sol_map_states = [state for state in states(systems[1]) if first(values(state.metadata))[2] in sol_maps]

        data = [x => vec(sum(stack(en.weights .* [indsol[x] for indsol in sol]), dims = 2)) for x in sol_map_states]

        data

        state_symbs = [Symbol(pair.first) for pair in data]
        state_data = [dat.second for dat in data]
        dataframable_pairs = [state => data for (state,data) in zip(state_symbs,state_data)]

        DataFrame(:t => sol[1].t ,dataframable_pairs...)
