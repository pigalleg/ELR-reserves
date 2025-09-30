using JuMP
using Gurobi
# include("../utils.jl")
# include("../post_processing.jl")
include("./utils.jl")
include("../constraints.jl")


function DUC(gen_df, VLOL, VLGEN, mip_gap)
    model = Model()
    set_solver_attributes(model, mip_gap)
    # model = direct_model(Gurobi.Optimizer())
    # initialize_model(model, mip_gap)
    sets = get_sets(gen_df)
    G = sets.G
    G_thermal = sets.G_thermal
    G_var = sets.G_var
    G_nonvar = sets.G_nonvar
    G_nt_nonvar = sets.G_nt_nonvar
    T = sets.T
    T_red = sets.T_red
    VLOL = convert_to_indexed_vector(VLOL, T)
    VLGEN = convert_to_indexed_vector(VLGEN, T)

    @variable(model, p_DEMAND[t in T] in Parameter(0.0)) # time-dependent data
    @variable(model, p_MAX_GEN[g in G_var, T in T] in Parameter(0.0)) # time-dependent data
    @variable(model, p_VLOL[t in keys(VLOL)] in Parameter(VLOL[t])) # for post-processing purposes
    @variable(model, p_VLGEN[t in keys(VLGEN)] in Parameter(VLGEN[t])) # for post-processing purposes
    
    @variables(model, begin
        GEN[G,T] >= 0    # generation
        LOL[T] >= 0
        LGEN[T] >= 0
        COMMIT[G_thermal,T], Bin # commitment status (Bin=binary)
        START[G_thermal,T], Bin  # startup decision
        SHUT[G_thermal,T], Bin   # shutdown decision
    end)
         
  # Objective function
      # Sum of variable costs + start-up costs for all generators and time periods
      # TODO: add delta_T
    # Start cost =  start up O&M cost [$/start/MW] * START * CAPACITY [MW]
    @expression(model, StartCost,
        sum(gen_df[gen_df.r_id .== g,:start_cost_per_mw][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*START[g,t] for g in G_thermal for t in T)
    )
    # Variable cost [$]= (heat rate [MMBtu/MWh] * fuel cost [$/MMBtu] +  variable O&M [$/MWh]) * GEN [MWh] + 
    # Fixed cost [$]= (fixed O&M [$/MW/h] * capacity [MW] * COMMIT  +  fixed O&M [$/MW/h] * CAPACITY [MW]) * hours [h]
    @expression(model, OperationalCost,
        sum((gen_df[gen_df.r_id .== g,:heat_rate_mmbtu_per_mwh][1]*gen_df[gen_df.r_id .== g,:fuel_cost][1] + gen_df[gen_df.r_id .== g,:var_om_cost_per_mwh][1])*GEN[g,t] for g in G_nonvar for t in T) +
        sum(gen_df[gen_df.r_id .== g,:var_om_cost_per_mwh][1]*GEN[g,t]  for g in G_var for t in T) + 
        sum(gen_df[gen_df.r_id .== g,:fixed_om_cost_per_mw_per_hour][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*COMMIT[g,t] for g in G_thermal for t in T) + 
        sum(gen_df[gen_df.r_id .== g,:fixed_om_cost_per_mw_per_hour][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1] for g in G_nt_nonvar for t in T)
    )

    @expression(model, OPEX,
        StartCost + OperationalCost
    )
    @objective(model, Min,
        OPEX + sum(LOL[t]*VLOL[t] + LGEN[t]*VLGEN[t] for t in T)
    )
    # Demand balance constraint (supply must = demand in all time periods)
    # Expression is constructed to reuse during ED
    @expression(model, SupplyDemand[t in T],
        sum(GEN[g,t] for g in G) + LOL[t] - LGEN[t]
    )
    @constraint(model, SupplyDemandBalance[t in T], 
        SupplyDemand[t] == p_DEMAND[t] 
    )

    add_capacity_constraints(model, gen_df, sets)

    # Unit commitment constraints
    # 1. Minimum up time
    @constraint(model, Startup[g in G_thermal, t in T],
        COMMIT[g, t] >= sum(START[g, tt] for tt in intersect(T, (t-gen_df[gen_df.r_id .== g,:up_time][1]):t))
    )
    # 2. Minimum down time
    @constraint(model, Shutdown[g in G_thermal, t in T],
        1-COMMIT[g, t] >= sum(SHUT[g, tt] for tt in intersect(T, (t-gen_df[gen_df.r_id .== g,:down_time][1]):t))
    )

    # 3. Start up/down logic
    @constraint(model, CommitmentStatus[g in G_thermal, t in T_red],
        COMMIT[g,t+1] - COMMIT[g,t] == START[g,t+1] - SHUT[g,t+1]
    )

    return model
end


function add_storage_reserve_power_constraints(model, storage, sets)
    T = sets.T
    S = create_storage_sets(storage)
    CH = model[:CH]
    DIS = model[:DIS]
    @variables(model, begin
        RESUPDIS[S, T] >= 0
        RESUPCH[S, T] >= 0
        RESDNCH[S, T] >= 0
        RESDNDIS[S, T] >= 0
        # U[s,t] = 0 reserve up offered only by reducing charging rate. 
        # U[s,t] = 1 reserve up offered by reducing charging rate to 0 + increasing discharging rate
        U[S,T], Bin 
        # D[s,t] = 0 reserve down offered only by reducing discharging. 
        # D[s,t] = 1 reserve down offered by reducing discharging rate to 0 + increasing charging rate
        D[S,T], Bin
    end)

    # Reserve up logic - power constraints
    @constraint(model, ResUpStorageDisCapacityMax[s in S, t in T],
        RESUPDIS[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1] - DIS[s,t]
    )
    @constraint(model, ResUpStorageDisLogic[s in S, t in T], #comment this block to obtain Brunninx
        RESUPDIS[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*U[s,t]
    )
    @constraint(model, ResUpStorageChCapacityMax[s in S, t in T],
        RESUPCH[s,t] <= + CH[s,t]
    )
    @constraint(model, ResUpStorageChLogic[s in S, t in T], #comment this block to obtain Brunninx
        CH[s,t] - RESUPCH[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*(1-U[s,t])
    )
    # Reserve down logic - power constraints
    @constraint(model, ResDownStorageChCapacityMax[s in S, t in T],
        RESDNCH[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1] - CH[s,t]
    )
    @constraint(model, ResDownStorageChLogic[s in S, t in T], #comment this block to obtain Brunninx
        RESDNCH[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*D[s,t]
    )
    @constraint(model, ResDownStorageDisCapacityMax[s in S, t in T],
        RESDNDIS[s,t] <= + DIS[s,t]
    )
    @constraint(model, ResDownStorageDisLogic[s in S, t in T], #comment this block to obtain Brunninx
        DIS[s,t] - RESDNDIS[s,t] <= storage[storage.r_id .== s,:existing_cap_mw][1]*(1-D[s,t])
    )
end

function add_reserve_constraints(model, gen_df, storage::Union{DataFrame, Nothing}, bidirectional_storage_reserve::Bool, storage_envelopes::Bool, naive_envelopes::Bool, thermal_reserve::Bool, storage_reserve_repartition::Union{Int64,Float64}, inflows::Bool, VRESERVE::Union{Int64,Float64}, VSRESUP::Union{Int64,Float64}, VSRESDN::Union{Int64,Float64}, sets::NamedTuple)
    G_thermal = sets.G_thermal
    T = sets.T
    T_red = sets.T_red
    GEN = model[:GEN]
    COMMIT = model[:COMMIT]
    G_reserve = G_thermal
    VSRESUP = convert_to_indexed_vector(VSRESUP, T)
    VSRESDN = convert_to_indexed_vector(VSRESDN, T)

    if !isnothing(storage)
        S = create_storage_sets(storage)
        G_reserve = union(G_thermal, S)
    end
    @variables(model, begin
        RESUP[G_reserve, T] >= 0
        RESDN[G_reserve, T] >= 0
        SRESUP[T] >= 0 # RESUP slack
        SRESDN[T] >= 0 # RESDN slack
    end)
    @variable(model, p_VRESERVE in Parameter(VRESERVE)) # used for post-processing
    @variable(model, p_VSRESUP[t in T] in Parameter(VSRESUP[t])) # for post-processing purposes
    @variable(model, p_VSRESDN[t in T] in Parameter(VSRESDN[t])) # for post-processing purposes
    
    @variable(model, RRESUP[t in T] in Parameter(0.0)) # time-dependent data
    @variable(model, RRESDN[t in T] in Parameter(0.0)) # time-dependent data

    @expression(model, ReservePenalizationCost,
        VRESERVE*sum(RESUP[g,t] + RESDN[g,t] for g in G_reserve, t in T)
    )
    @expression(model, ReserveSlackPenalizationCost,
        sum(SRESUP[t]*VSRESUP[t] for t in T) + sum(SRESDN[t]*VSRESDN[t] for t in T)
    )
    @objective(model, Min, 
        objective_function(model) + model[:ReservePenalizationCost] + model[:ReserveSlackPenalizationCost]
    )
    
    add_thermal_reserve_power_constraints(model, gen_df, sets)
    if !thermal_reserve
        for g in G_thermal, t in T
            fix(RESUP[g,t], 0.0, force = true)
            fix(RESDN[g,t], 0.0, force = true)
        end
    end


    # (3) Storage reserve
    if !isnothing(storage)
        S = create_storage_sets(storage)
        SOE = model[:SOE]
        add_storage_reserve_power_constraints(model, storage, sets)
        RESUPDIS = model[:RESUPDIS]
        RESUPCH = model[:RESUPCH]
        RESDNCH = model[:RESDNCH]
        RESDNDIS = model[:RESDNDIS]
        RRESUP = model[:RRESUP]
        RRESDN = model[:RRESDN]

        # Energy constraints # important for μ=0 ?
        # @constraint(model, ResUpStorageDisMax[s in S, t in T],
        #     RESUPDIS[s,t] <= (SOE[s,t]- storage[storage.r_id .== s,:min_energy_mwh][1])*storage[storage.r_id .== s,:discharge_efficiency][1] #TODO: include delta_T
        # )
        # @constraint(model, ResDownStorageChMax[s in S, t in T],
        #     RESDNCH[s,t] <= (storage[storage.r_id .== s,:max_energy_mwh][1] - SOE[s,t])/storage[storage.r_id .== s,:charge_efficiency][1] #TODO: include delta_T
        # )
        
        @constraint(model, ResUpStorageCapacityMax[s in S, t in T],
            RESUP[s,t] == RESUPDIS[s,t] + RESUPCH[s,t]
        )
        @constraint(model, ResDownStorageCapacityMax[s in S, t in T],
            RESDN[s,t] == RESDNCH[s,t] + RESDNDIS[s,t]
        )

        if !bidirectional_storage_reserve
            U = model[:U]
            D = model[:D]
            for s in S, t in T
                fix(RESUPCH[s,t], 0, force = true)
                fix(RESDNDIS[s,t], 0, force = true)
                fix(U[s,t], 1, force = true)
                fix(D[s,t], 1, force = true)
            end
            remove_variable_constraint(model, :ResUpStorageDisLogic)
            remove_variable_constraint(model, :ResUpStorageChLogic)
            remove_variable_constraint(model, :ResDownStorageChLogic)
            remove_variable_constraint(model, :ResDownStorageDisLogic)
            
        end

        if storage_envelopes # TODO: change this to default when reserves are active
            println("Adding storage envelopes...")
            add_envelope_constraints(model, storage, naive_envelopes)
        end
        if storage_reserve_repartition >=0
            @warn "Storage reserve repartition is currently disabled. No constraints are being added."
            # WARNING: storage reserve repartition disabled
            # println("Adding storage reserve repartition...")
            # add_storage_reserve_repartition(model, reserve, storage_reserve_repartition, sets)
        end 
        if inflows
            S_inflows = create_storage_inflows_set(storage)
            for s in S_inflows, t in T
                fix(RESUPCH[s,t], 0.0, force = true)
                fix(RESDNCH[s,t], 0.0, force = true)
            end
        end
    end

    # (4) Overall reserve requirements
    @constraint(model, ResUpRequirement[t in T],
        sum(RESUP[g,t] for g in G_reserve) + SRESUP[t] >= RRESUP[t]
    )
    @constraint(model, ResDnRequirement[t in T],
        sum(RESDN[g,t] for g in G_reserve) + SRESDN[t] >= RRESDN[t]
    )
end


function add_thermal_reserve_power_constraints(model, gen_df, sets)
    G_thermal = sets.G_thermal
    T = sets.T
    T_red = sets.T_red
    GEN = model[:GEN]
    COMMIT = model[:COMMIT]
    GENAUX = model[:GENAUX]
    if haskey(model, :RESUP) && haskey(model, :RESDN)
        RESUP = model[:RESUP]
        RESDN = model[:RESDN]
    else
        @variables(model, begin
            RESUP[G_thermal, T] >= 0 # reserve up offered by thermal generators
            RESDN[G_thermal, T] >= 0 # reserve down offered by thermal generators
        end)
    end
    
    # (1) Reserves limited by committed capacity of generator
    @constraint(model, ResUpThermal[g in G_thermal, t in T],
        RESUP[g,t] <= COMMIT[g,t]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1] - GEN[g,t]
    )
    @constraint(model, ResDnThermal[g in G_thermal, t in T],
        RESDN[g,t] <= GEN[g,t] - COMMIT[g,t]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:min_power][1]
    ) #TODO: calculation should be done at input file
    if haskey(model, :RampUp_thermal) # adding only if ramp constraints are present
        # (2) Reserves limited by ramp rates #TODO: check if this restrictions make sense
        @constraint(model, ResUpRamp[g in G_thermal, t in T],
            RESUP[g,t] <=  gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_up_percentage][1]
        )
        @constraint(model, ResDnRamp[g in G_thermal, t in T],
            RESDN[g,t] <=  gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_dn_percentage][1]
        )
        # (3) Robust ramp constraints
        @constraint(model, ResUpRampRobust[g in G_thermal, t in T_red],
            GENAUX[g,t+1] + RESUP[g,t+1] - (GENAUX[g,t] - RESDN[g,t]) <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_up_percentage][1]
        )
        @constraint(model, ResDnRampRobust[g in G_thermal, t in T_red],
            GENAUX[g,t] + RESUP[g,t] - (GENAUX[g,t+1] - RESDN[g,t+1]) <= gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*gen_df[gen_df.r_id .== g,:ramp_dn_percentage][1]
        )
    end
end

function add_storage_reserve_repartition(model, reserve, storage_reserve_repartition, sets)
    RESUP = model[:RESUP]
    RESDN = model[:RESDN]
    SRESUP = model[:SRESUP]
    SRESDN = model[:SRESDN]
    S = axes(model[:SOE])[1]
    T = sets.T
    not_S = setdiff(axes(model[:RESUP])[1],S)
    @constraint(model, ResUpStorageRepartition,
        sum(RESUP[s,t] for s in S, t in T) == storage_reserve_repartition * (sum(reserve[:,:reserve_up_MW]) - sum(SRESUP[t] for t in T)) 
    )
    @constraint(model, ResDnStorageRepartition,
        sum(RESDN[s,t] for s in S, t in T) == storage_reserve_repartition * (sum(reserve[:,:reserve_down_MW])- sum(SRESDN[t] for t in T))
    )
    @constraint(model, ResUpNotStorageRepartition,
        sum(RESUP[s,t] for s in not_S, t in T) == (1-storage_reserve_repartition) * (sum(reserve[:,:reserve_up_MW]) - sum(SRESUP[t] for t in T))
    )
    @constraint(model, ResDnNotStorageRepartition,
        sum(RESDN[s,t] for s in not_S, t in T) == (1-storage_reserve_repartition) * (sum(reserve[:,:reserve_down_MW])- sum(SRESDN[t] for t in T))
    )
end

function add_envelope_constraints(model, storage, naive_envelopes = false)
    S = create_storage_sets(storage)
    RESUPCH = model[:RESUPCH]
    RESDNCH = model[:RESDNCH]
    RESUPDIS = model[:RESUPDIS]
    RESDNDIS = model[:RESDNDIS]

    SOE = model[:SOE]
    CH = model[:CH]
    DIS = model[:DIS]
    T, _ =  create_time_sets()
    T_incr = copy(T)
    pushfirst!(T_incr, T_incr[1]-1)

    @variables(model, begin
        SOEUP[S, T_incr] >= 0
        SOEDN[S, T_incr] >= 0
    end)
    if !naive_envelopes
        @constraint(model, SOEUpEvol[s in S, t in T],
            SOEUP[s,t] == SOE[s,t] + sum(RESDNCH[s,tt]*storage[storage.r_id .== s,:charge_efficiency][1] + RESDNDIS[s,tt]/storage[storage.r_id .== s,:discharge_efficiency][1] for tt in T if tt <= t)

        ) #TODO: add delta_T
        @constraint(model, SOEDnEvol[s in S, t in T], 
            SOEDN[s,t] == SOE[s,t] - sum(RESUPCH[s,tt]*storage[storage.r_id .== s,:charge_efficiency][1] + RESUPDIS[s,tt]/storage[storage.r_id .== s,:discharge_efficiency][1] for tt in T if tt <= t)
        ) #TODO: add delta_T
    else # deprecated
        @constraint(model, SOEUpEvol[s in S, t in T],
            SOEUP[s,t]  == SOE[s,t] + RESDNCH[s,t]*storage[storage.r_id .== s,:charge_efficiency][1] + RESDNDIS[s,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
        ) 
        @constraint(model, SOEDnEvol[s in S, t in T], 
            SOEDN[s,t]  == SOE[s,t] - RESUPCH[s,t]*storage[storage.r_id .== s,:charge_efficiency][1] - RESUPDIS[s,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
        )
    end
    # SOEUP_T_initial = SOE_T_initial
    @constraint(model, SOEUP_0[s in S],
        SOEUP[s,T_incr[1]] == SOE[s,T_incr[1]]
    )
    # SOEDN_T_initial = SOE_T_initial
    @constraint(model, SOEDN_0[s in S],
        SOEDN[s,T_incr[1]] == SOE[s,T_incr[1]]
    )
    
    # SOEUP, SOEDN <=SOE_max
    @constraint(model, SOEUPMax[s in S, t in T],
        SOEUP[s,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    @constraint(model, SOEDNMax[s in S, t in T],
        SOEDN[s,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    
    # SOEUP, SOEDN>=SOE_min
    @constraint(model, SOEUPMin[s in S, t in T],
        SOEUP[s,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
    )
    @constraint(model, SOEDNMin[s in S, t in T],
        SOEDN[s,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
    )
end

function add_energy_reserve_constraints(model, gen_df, storage::Union{DataFrame, Nothing}, storage_envelopes::Bool, storage_link_constraint::Bool, thermal_reserve::Bool, inflows::Bool, VRESERVE::Union{Int64,Float64}, VSRESUP::Union{Int64,Float64}, VSRESDN::Union{Int64,Float64}, sets::NamedTuple)
    G_thermal = sets.G_thermal
    T = sets.T
    T_red = sets.T_red
    GEN = model[:GEN]
    COMMIT = model[:COMMIT]
    VSRESUP = convert_to_indexed_vector(VSRESUP, T)
    VSRESDN = convert_to_indexed_vector(VSRESDN, T)

    G_reserve = G_thermal
    if !isnothing(storage)
        S = create_storage_sets(storage)
        G_reserve = union(G_thermal, S)
        SOE = model[:SOE]
    end

    @variable(model, p_VRESERVE in Parameter(VRESERVE)) # used for postprocessing
    @variable(model, p_VSRESUP[t in keys(VSRESUP)] in Parameter(VSRESUP[t])) # for postprocessing purposes
    @variable(model, p_VSRESDN[t in keys(VSRESDN)] in Parameter(VSRESDN[t]))
    @variable(model, RERESUP[j in T, t in T; j <= t] in Parameter(0))
    @variable(model, RERESDN[j in T, t in T; j <= t] in Parameter(0))

    @variables(model, begin
        ERESUP[G_reserve, j in T, t in T; j <= t] >= 0
        ERESDN[G_reserve, j in T, t in T; j <= t] >= 0
        SERESUP[j in T, t in T; j <= t] >= 0 # ERESUP slack
        SERESDN[j in T, t in T; j <= t] >= 0 # ERESDN slack
    end)

    @expression(model, EnergyReservePenalizationCost,
        VRESERVE*sum(ERESUP[g,j,t] + ERESDN[g,j,t] for g in G_reserve, j in T, t in T if j <= t)
    )
    
    @expression(model, EnergyReserveSlackPenalizationCost,
        sum(SERESUP[j,t]*VSRESUP[t] for j in T, t in T if j <= t) + sum(SERESDN[j,t]*VSRESDN[t] for j in T, t in T if j <= t)
    )

    @objective(model, Min, 
        objective_function(model) + model[:EnergyReservePenalizationCost] + model[:EnergyReserveSlackPenalizationCost]
    )

    add_thermal_reserve_power_constraints(model, gen_df, sets)
    RESUP = model[:RESUP]
    RESDN = model[:RESDN]

    # (1) Reserves limited by committed capacity of generator
    @constraint(model, EnergyResUpThermal[g in G_thermal, j in T, t in T; j <= t],
        ERESUP[g,j,t] <= sum(RESUP[g,tt] for tt in T if (tt >= j)&(tt <= t))
    )
    @constraint(model, EnergyResDownThermal[g in G_thermal, j in T, t in T; j <= t],
        ERESDN[g,j,t] <= sum(RESDN[g,tt] for tt in T if (tt >= j)&(tt <= t))
    )

    if !thermal_reserve
        for (g,j,t) in [(g,j,t) for g in G_thermal, j in T, t in T if j <= t]
            fix(ERESUP[g,j,t], 0.0, force = true)
            fix(ERESDN[g,j,t], 0.0, force = true)
        end
    end
    # (3) Storage reserve
    if !isnothing(storage)
        # -- begin -- 
        # Following variables are not constrained when energy reserves are used.
        add_storage_reserve_power_constraints(model, storage, sets)
        RESUPDIS = model[:RESUPDIS]
        RESUPCH = model[:RESUPCH]
        RESDNCH = model[:RESDNCH]
        RESDNDIS = model[:RESDNDIS]
        # --end --
        @variables(model, begin
            ERESUPDIS[S, j in T, t in T; j <= t] >= 0
            ERESUPCH[S, j in T, t in T; j <= t] >= 0
            ERESDNCH[S, j in T, t in T; j <= t] >= 0
            ERESDNDIS[S, j in T, t in T; j <= t] >= 0
        end)

        # Power constraints 
        @constraint(model, EnergyResUpStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
            ERESUPDIS[s,j,t] <= sum(RESUPDIS[s,tt] for tt in T if (tt >= j)&(tt <= t))
        )
        @constraint(model, EnergyResUpStorageChCapacityMax[s in S, j in T, t in T; j <= t],
            ERESUPCH[s,j,t] <= sum(RESUPCH[s,tt] for tt in T if (tt >= j)&(tt <= t))
        )
        @constraint(model, EnergyResDownStorageChCapacityMax[s in S, j in T, t in T; j <= t],
            ERESDNCH[s,j,t] <= sum(RESDNCH[s,tt] for tt in T if (tt >= j)&(tt <= t))
        )
        @constraint(model, EnergyResDownStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
            ERESDNDIS[s,j,t] <= sum(RESDNDIS[s,tt] for tt in T if (tt >= j)&(tt <= t))
        )

        # Energy constraints
        # @constraint(model, EnergyResUpStorageEnergyMax[s in S, j in T, t in T; j <= t], # important for μ<1
        #     ERESUPDIS[s,j,t] <= (SOE[s,t]- storage[storage.r_id .== s,:min_energy_mwh][1])*storage[storage.r_id .== s,:discharge_efficiency][1]
        # )
        # @constraint(model, EnergyResDownStorageEnergyMax[s in S, j in T, t in T; j <= t], # important for μ<1
        #     ERESDNCH[s,j,t] <= (storage[storage.r_id .== s,:max_energy_mwh][1] - SOE[s,t])/storage[storage.r_id .== s,:charge_efficiency][1]
        # )

        # Energy constraints / envelope-like constraints
        @constraint(model, EnergyResUpStorage[s in S, j in T, t in T; j <= t],
            ERESUP[s,j,t] == ERESUPDIS[s,j,t] + ERESUPCH[s,j,t]
        )
        @constraint(model, EnergyResDownStorage[s in S, j in T, t in T; j <= t],
            ERESDN[s,j,t] == ERESDNCH[s,j,t] + ERESDNDIS[s,j,t]
        )

        if storage_envelopes
            println("Adding storage energy envelopes...")
            add_energy_envelope_constraints(model, storage, sets)
        end

        if storage_link_constraint
            @constraint(model, EnergyResUpLink[s in S, j in T, t in T; j <= t],
                ERESUPDIS[s,j,t] == sum(ERESUPDIS[s, tt, tt] for tt in T if (tt >= j)&(tt <= t))
            )
            @constraint(model, EnergyResUpLinkBis[s in S, j in T, t in T; j <= t],
                ERESUPCH[s,j,t] == sum(ERESUPCH[s, tt, tt] for tt in T if (tt >= j)&(tt <= t))
            )
            @constraint(model, EnergyResDownLink[s in S, j in T, t in T; j <= t],
                ERESDNCH[s,j,t] == sum(ERESDNCH[s, tt, tt] for tt in T if (tt >= j)&(tt <= t))
            )
            @constraint(model, EnergyResDownLinkBis[s in S, j in T, t in T; j <= t],
                ERESDNDIS[s,j,t] == sum(ERESDNDIS[s, tt, tt] for tt in T if (tt >= j)&(tt <= t))
            )
        end
        if inflows
            S_inflows = create_storage_inflows_set(storage)
            for s in S_inflows, j in T, t in T if j <= t
                    fix(ERESUPCH[s,j,t], 0.0, force = true)
                    fix(ERESDNCH[s,j,t], 0.0, force = true)
                end
            end
        end
    end

    # (4) Overall reserve requirements
    @constraint(model, EnergyResUpRequirement[j in T, t in T; j <= t],
        sum(ERESUP[i,j,t] for i in G_reserve) + SERESUP[j,t] >= RERESUP[j,t]
    )
 
    @constraint(model, EnergyResDnRequirement[j in T, t in T; j <= t],
        sum(ERESDN[i,j,t] for i in G_reserve) + SERESDN[j,t] >= RERESDN[j,t]
    )

end


function add_energy_envelope_constraints(model, storage, sets)
    SOE = model[:SOE]
    S = axes(SOE)[1]
    T = sets.T

    T_incr = axes(SOE)[2]
    
    ERESUPCH = model[:ERESUPCH]
    ERESDNCH = model[:ERESDNCH]
    ERESUPDIS = model[:ERESUPDIS]
    ERESDNDIS = model[:ERESDNDIS]

    @variables(model, begin
        ESOEUP[S, j in T_incr, t in T_incr; j <= t] >= 0
        ESOEDN[S, j in T_incr, t in T_incr; j <= t] >= 0
    end)
    @constraint(model, ESOEUpEvol[s in S, j in T, t in T; j <= t],
        ESOEUP[s,j,t]  == SOE[s,t] + ERESDNCH[s,j,t]*storage[storage.r_id .== s,:charge_efficiency][1] + ERESDNDIS[s,j,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    )
    @constraint(model, ESOEDnEvol[s in S, j in T, t in T; j <= t], 
        ESOEDN[s,j,t]  == SOE[s,t] - ERESUPCH[s,j,t]*storage[storage.r_id .== s,:charge_efficiency][1] - ERESUPDIS[s,j,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    )

    # ESOEUP[T_initial,T_initial] = SOE[T_initial]
    @constraint(model, SOEUP_0[s in S, t in T_incr],
        ESOEUP[s,T_incr[1],T_incr[1]] == SOE[s,T_incr[1]]
    )
    # ESOEDN[T_initial,T_initial] = SOE[T_initial]
    @constraint(model, SOEDN_0[s in S, t in T_incr],
        ESOEDN[s,T_incr[1], T_incr[1]] == SOE[s,T_incr[1]]
    )
    @constraint(model, SOEUPEvol_0[s in S, t in T],
        ESOEUP[s,T_incr[1],t] == ESOEUP[s,T[1],t]
    )
    @constraint(model, SOEDNEvol_0[s in S, t in T],
        ESOEDN[s,T_incr[1],t] == ESOEDN[s,T[1],t]
    )
    
    # SOEUP, SOEDN <=SOE_max
    @constraint(model, ESOEUPMax[s in S, j in T, t in T; j <= t],
        ESOEUP[s,j,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    @constraint(model, ESOEDNMax[s in S, j in T, t in T; j <= t],
        ESOEDN[s,j,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
    )
    
    # SOEUP, SOEDN>=SOE_min
    @constraint(model, ESOEUPMin[s in S, j in T, t in T; j <= t],
        ESOEUP[s,j,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
    )
    @constraint(model, ESOEDNMin[s in S, j in T, t in T; j <= t],
        ESOEDN[s,j,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
    )
end


function set_envelope_multipliers(model, μ_up, μ_dn, storage)
    println("μ_up")
    println("μ_dn")
    SOEUpEvol = model[:SOEUpEvol]
    SOEDnEvol = model[:SOEDnEvol]
    RESUPCH = model[:RESUPCH]
    RESUPDIS = model[:RESUPDIS]
    RESDNCH = model[:RESDNCH]
    RESDNDIS = model[:RESDNDIS]
    for s in axes(SOEUpEvol)[1], t in axes(SOEUpEvol)[2]
        for tt in axes(SOEUpEvol)[2]
            if tt <= t
                set_normalized_coefficient(SOEUpEvol[s,t], RESDNCH[s,tt], -μ_dn[tt]*storage[storage.r_id .== s,:charge_efficiency][1])
                set_normalized_coefficient(SOEUpEvol[s,t], RESDNDIS[s,tt], -μ_dn[tt]/storage[storage.r_id .== s,:discharge_efficiency][1])
                set_normalized_coefficient(SOEDnEvol[s,t], RESUPCH[s,tt], μ_up[tt]*storage[storage.r_id .== s,:charge_efficiency][1])
                set_normalized_coefficient(SOEDnEvol[s,t], RESUPDIS[s,tt], μ_up[tt]/storage[storage.r_id .== s,:discharge_efficiency][1])
            end
        end
    end 
end

function set_energy_envelope_multipliers(model, μ_up, μ_dn, storage)
    # ESOEUP[s,j,t]  == SOE[s,t] + p_μ_DN[t]*ERESDNCH[s,j,t]*storage[storage.r_id .== s,:charge_efficiency][1] + p_μ_DN[t]*ERESDNDIS[s,j,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    # ESOEDN[s,j,t]  == SOE[s,t] - p_μ_UP[t]*ERESUPCH[s,j,t]*storage[storage.r_id .== s,:charge_efficiency][1] - p_μ_UP[t]*ERESUPDIS[s,j,t]/storage[storage.r_id .== s,:discharge_efficiency][1]
    println("μ_up")
    println("μ_dn")
    ESOEUpEvol = model[:ESOEUpEvol]
    ESOEDnEvol = model[:ESOEDnEvol]
    ERESUPCH = model[:ERESUPCH]
    ERESUPDIS = model[:ERESUPDIS]
    ERESDNCH = model[:ERESDNCH]
    ERESDNDIS = model[:ERESDNDIS]
    for (s,j,t) in eachindex(ESOEUpEvol) 
        set_normalized_coefficient(ESOEUpEvol[s,j,t], ERESDNCH[s,j,t], -μ_dn[t]*storage[storage.r_id .== s,:charge_efficiency][1])
        set_normalized_coefficient(ESOEUpEvol[s,j,t], ERESDNDIS[s,j,t], -μ_dn[t]/storage[storage.r_id .== s,:discharge_efficiency][1])
        set_normalized_coefficient(ESOEDnEvol[s,j,t], ERESUPCH[s,j,t], μ_up[t]*storage[storage.r_id .== s,:charge_efficiency][1])
        set_normalized_coefficient(ESOEDnEvol[s,j,t], ERESUPDIS[s,j,t], μ_up[t]/storage[storage.r_id .== s,:discharge_efficiency][1])
    end 
end