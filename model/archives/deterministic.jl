function add_MGA_constraints(model, reference_solution)
    #deprecated
  
    reference_objective_function = objective_value(model)
    
    mip_gap = get_optimizer_attribute(model,"MIPGap")
    primal = objective_bound(model)
    dual = dual_objective_value(model)

    T = axes(model[:ResUpThermal])[2]
    G_thermal = axes(model[:ResUpThermal])[1]
    S = axes(model[:ResUpStorageCapacityMax])[1]
    RESUP = model[:RESUP]
    RESDN = model[:RESDN]
    COMMIT = model[:COMMIT]
    # LOL  = model[:LOL]
    # remove_variable_constraint(model, :OVMax)
    # remove_variable_constraint(model, :OVMin)
    # remove_variable_constraint(model, :ResUpThermalMin)
    # remove_variable_constraint(model, :ResDownThermalMin)
    # remove_variable_constraint(model, :CommitmentMin)
    # remove_variable_constraint(model, :ResUpStorageMax)
    # remove_variable_constraint(model, :ResUpStorageMin)

    @constraint(model, OVMax,
        objective_function(model) <= (1+mip_gap)*primal
        # objective_function(model) <= primal
    )
    @constraint(model, OVMin,
        objective_function(model) >= (1-mip_gap)*primal
        # objective_function(model) >= dual
    )

    # set_optimizer_attribute(model, "PoolGap", mip_gap)
    
    # @constraint(model, ResUpStorageMin[s in S, t in T],
    #     RESUP[s,t] >=  (filter([:r_id, :hour] => ((x,y) -> (x == s)*(y==t)), reference_solution.reserve).reserve_up_MW)[1]
    # )
    # T_ = 169:176
    # T_ = [172]
    # @constraint(model, ResUpStorageMax[t in T_],
    #     RESUP[101,t] <=  0
    # )
    # @constraint(model, ResUpStorageMax[s in S, t in T],
    #     RESUP[s,t] <=  (filter([:r_id, :hour] => ((x,y) -> (x == s)*(y==t)), reference_solution.reserve).reserve_up_MW)[1]
    # )
    # @constraint(model, ResDownStorageMin[s in S, t in T],,
    #     sum(RESDN[i,t] for i in G_thermal, t in T) >=  sum(filter(:r_id => x -> x in G_thermal, reference_solution.reserve).reserve_down_MW)
    # )

    # @constraint(model, ResUpThermalMin,
    #     sum(RESUP[i,t] for i in G_thermal, t in T) >=  sum(filter(:r_id => x -> x in G_thermal, reference_solution.reserve).reserve_up_MW)
    # )
    # @constraint(model, ResDownThermalMin,
    #     sum(RESDN[i,t] for i in G_thermal, t in T) >=  sum(filter(:r_id => x -> x in G_thermal, reference_solution.reserve).reserve_down_MW)
    # )

    # @constraint(model, ResUpThermalMin[t in T],
    #     sum(RESUP[i,t] for i in G_thermal) >=  sum(filter([:r_id, :hour] => ((x,y) -> (x in G_thermal)*(y==t)), reference_solution.reserve).reserve_up_MW)
    # )
    # @constraint(model, ResDownThermalMin[t in T],
    #     sum(RESDN[i,t] for i in G_thermal) >=  sum(filter([:r_id, :hour] => ((x,y) -> (x in G_thermal)*(y==t)), reference_solution.reserve).reserve_down_MW)
    # )

    
    # @constraint(model, CommitmentMin,
    #     sum(COMMIT[i,t] for i in G_thermal, t in T) >= sum(filter(:r_id => x -> x in G_thermal, reference_solution.generation).commit)
    # )

    # @constraint(model, ResUpThermalMin[i in G_thermal, t in T],
    # RESUP[i,t] >=  sum(filter([:r_id, :hour] => ((x,y) -> (x ==i)*(y==t)), reference_solution.reserve).reserve_up_MW)
    # )
    # @constraint(model, ResDownThermalMin[i in G_thermal, t in T],
    #     RESDN[i,t] >=  sum(filter([:r_id, :hour] => ((x,y) -> (x ==i)*(y==t)), reference_solution.reserve).reserve_down_MW)
    # )
    # @constraint(model, CommitmentMin[i in G_thermal, t in T],
    #     COMMIT[i,t] >= sum(filter([:r_id, :hour] => ((x,y) -> (x ==i)*(y==t)), reference_solution.generation).commit)
    # )
end

function generate_alternative_model(model, reference_solution)
    # Assumes reference_solution is enriched (cf. enrich_dfs())
    println("Adding MGA constraints...")
    # model = JuMP.copy(model)
    # set_optimizer(model, Gurobi.Optimizer) 
    optimize!(model) # Optimizitation is needed since OV will be used as reference.
    # aux = get_solution(uc).scalar.objective_value[1]
    add_MGA_constraints(model, reference_solution)
    # optimize!(model)
    return model
end

