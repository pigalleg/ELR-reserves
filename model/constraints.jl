# Common constraints between UC and ED models

function add_capacity_constraints(model, gen_df, sets)
    T = sets.T
    G_nt_nonvar = sets.G_nt_nonvar
    G_var = sets.G_var
    G_thermal = sets.G_thermal

    GEN = model[:GEN]
    p_MAX_GEN = model[:p_MAX_GEN]
    COMMIT = model[:COMMIT]

    # 1. thermal generators requiring commitment
    @constraint(model, Cap_thermal_min[g in G_thermal, t in T], 
        GEN[g,t] >= COMMIT[g, t]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:min_power][1] 
    ) 
    @constraint(model, Cap_thermal_max[g in G_thermal, t in T], 
        GEN[g,t] <= COMMIT[g, t]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]
    ) 
    # 2. non-variable generation not requiring commitment
    @constraint(model, Cap_nt_nonvar[g in G_nt_nonvar, t in T], 
        GEN[g,t] <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]
    )
    # 3. variable generation, accounting for hourly capacity factor
    @constraint(model, Cap_var[g in G_var, t in T],
        GEN[g,t] == p_MAX_GEN[g,t]
    )
end

function add_ramp_constraints(model, gen_df, sets)
    G = sets.G
    G_thermal = sets.G_thermal
    G_nonthermal = sets.G_nonthermal
    T = sets.T
    T_red = sets.T_red

    GEN = model[:GEN]
    COMMIT = model[:COMMIT]

    # New auxiliary variable GENAUX for generation above the minimum output level
    @variable(model, GENAUX[G_thermal, T] >= 0)
    
    # for committed thermal units (only created for thermal generators)
    @constraint(model, AuxGen[g in G_thermal, t in T],
        GENAUX[g,t] == GEN[g,t] - COMMIT[g,t]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:min_power][1]
    )
    
    # Ramp equations for thermal generators (constraining GENAUX)
    @constraint(model, RampUp_thermal[g in G_thermal, t in T_red], 
        GENAUX[g,t+1] - GENAUX[g,t] <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_up_percentage][1]
    )

    @constraint(model, RampDn_thermal[g in G_thermal, t in T_red], 
        GENAUX[g,t] - GENAUX[g,t+1] <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_dn_percentage][1]
    )
    # Ramp equations for non-thermal generators (constraining total generation GEN)
    @constraint(model, RampUp_nonthermal[g in G_nonthermal, t in T_red], 
        GEN[g,t+1] - GEN[g,t] <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_up_percentage][1]
    )
    # @constraint(model, RampDn[i in G, t in T_red], 
    #     GEN[i,t] - GEN[i,t+1] <= gen_df[gen_df.r_id .== i,:existing_cap_mw][1] * 
    #                              gen_df[gen_df.r_id .== i,:ramp_dn_percentage][1])

    @constraint(model, RampDn_nonthermal[g in G_nonthermal, t in T_red], 
        GEN[g,t] - GEN[g,t+1] <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_dn_percentage][1]
    )
end


function add_storage(model, storage, sets; inflows = false, SOE_final_strict = true, VSSOEFinal = 0)
    T = sets.T 
    T_incr = copy(T)
    pushfirst!(T_incr, T_incr[1]-1) # T_incr = [t[1]-1,T]
    S = create_storage_sets(storage)
    if inflows
        S_inflows = create_storage_inflows_set(storage)
        @variable(model, p_INFLOW[s in S_inflows, t in T] in Parameter(0.0)) # time-dependent data
    else
        S_inflows = []
    end
    # GEN = model[:GEN]
    p_DEMAND = model[:p_DEMAND]
    # START = model[:START]
    
    @variables(model, begin
        CH[S,T] >= 0
        DIS[S,T] >= 0
        SOE[S,T_incr] >= 0 # T_incr captures SOE at t = T[1]-1
        M[S,T], Bin # (charging mode) M[s,t] = 1  => DIS[s,t] = 0, (discharging mode) M[s,t] = 0 => CH[s,t] = 0
    end)

    # Redefinition of objecive function
    @expression(model, StorageOperationalCost,
        sum(storage[storage.r_id .== s,:var_om_cost_per_mwh][1]*(CH[s,t] + DIS[s,t]) for s in S, t in T)
    )

    @objective(model, Min,
        objective_function(model) + StorageOperationalCost
    )

    OPEX = model[:OPEX]
    remove_variable_constraint(model, :OPEX, false)
    @expression(model, OPEX,
        OPEX + StorageOperationalCost
    )

    # Redefinition of supply-demand balance expression and constraint
    SupplyDemand = model[:SupplyDemand]
    # unregister(model, :SupplyDemand)
    remove_variable_constraint(model, :SupplyDemand, false)
    @expression(model, SupplyDemand[t in T],
        SupplyDemand[t] - sum(CH[s,t] - DIS[s,t] for s in S)
    )

    # SupplyDemandBalance = model[:SupplyDemandBalance]
    # delete.(model, SupplyDemandBalance) # Constraints must be deleted also
    # unregister(model, :SupplyDemandBalance)
    remove_variable_constraint(model, :SupplyDemandBalance, true)
    @constraint(model, SupplyDemandBalance[t in T], 
        SupplyDemand[t] == p_DEMAND[t]
    )

    # Charging-discharging logic
    @constraint(model, ChargeLogic[s in S, t in T],
        CH[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*M[s,t]
    )
    for s in S_inflows, t in T
        fix(CH[s,t], 0.0, force = true)
    end
    # @constraint(model, ChargeLogicInflow[s ∈ S_inflows, t in T],
    #     CH[s,t] == 0
    # )
    @constraint(model, DischargeLogic[s in S, t in T],
        DIS[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*(1-M[s,t])
    )
    
    # Storage constraints
    @constraint(model, SOEEvol[s in S, t in T; s ∉ S_inflows], 
        SOE[s,t] == SOE[s,t-1] + CH[s,t]*storage[storage.r_id .== s,:charge_efficiency][1] - DIS[s,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    ) #TODO: add delta_T

    @constraint(model, SOEEvolInflows[s in S, t in T; s ∈ S_inflows],
        SOE[s,t] == SOE[s,t-1] + p_INFLOW[s,t]*storage[storage.r_id .== s,:charge_efficiency][1] + CH[s,t]*storage[storage.r_id .== s,:charge_efficiency][1] - DIS[s,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    ) #TODO: add delta_T

    @constraint(model, SOEMax[s in S, t in T],
        SOE[s,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    @constraint(model, SOEMin[s in S, t in T],
        SOE[s,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
    )
    @constraint(model, CHMin[s in S, t in T],
        CH[s,t] >= storage[storage.r_id .== s,:existing_cap_mw][1]*storage[storage.r_id .== s,:min_power][1] #TODO: calculation should be done at input file
    )
    @constraint(model, DISMin[s in S, t in T],
        DIS[s,t] >= storage[storage.r_id .== s,:existing_cap_mw][1]*storage[storage.r_id .== s,:min_power][1] #TODO: calculation should be done at input file
    )
    # SOE_T_initial = SOE_0
    @constraint(model, SOEO[s in S], #TODO: replace by T
        SOE[s,T_incr[1]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    if SOE_final_strict
        @constraint(model, SOEFinal[s in S],
            SOE[s,T[end]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
        )
    else
        @variable(model, p_VSSOEFinal in Parameter(VSSOEFinal)) # for post-processing purposes
        @variable(model, SSOEFinal[S,T[end]] >= 0) # Needs to be defined as bidimentional for postprocessing purposes

        @expression(model, SOEFinalSlackPenalizationCost,
            sum(VSSOEFinal*SSOEFinal[s,T[end]] for s in S)
        )
        @objective(model, Min,
            objective_function(model) + SOEFinalSlackPenalizationCost
        )

        @constraint(model, SOEFinalSlack[s in S],
            SOE[s,T[end]] + SSOEFinal[s,T[end]] >= storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
        )

    end
end