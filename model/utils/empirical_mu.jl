using JuMP
using Gurobi
include("../unit_commitment/utils.jl")
function construct_empirical_µ(gen_df,  loads, storage, reserve, energy_reserve, mip_gap = 1e-4)
    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "MIPGap", mip_gap)
    sets = get_sets(gen_df, loads)
    T = sets.T
    T_incr = copy(T)
    pushfirst!(T_incr, T_incr[1]-1) # T_incr = [t[1]-1,T]
    S = create_storage_sets(storage)
    ηch = Dict(s => storage[storage.r_id .== s,:charge_efficiency][1] for s in S)
    ηdis = Dict(s => storage[storage.r_id .== s,:discharge_efficiency][1] for s in S)

    @variables(model, begin
        RESUP[S,T] >= 0 # power reseve up
        RESDN[S,T] >= 0 # power reserve down
        RESUPDIS[S,T]>= 0 # power reserve up from discharging
        RESUPCH[S,T]>= 0 # power reserve up from charging
        RESDNCH[S,T]>= 0 # power reserve dn fromcharging
        RESDNDIS[S,T]>= 0 # power reserve dn from discharging
    end)

    @variables(model, begin
        SOEUP[S, T_incr] >= 0
        SOEDN[S, T_incr] >= 0
    end)

    @variables(model, begin
        ERESUP[S, j in T, t in T; j <= t] >= 0 # energy reserve up
        ERESDN[S, j in T, t in T; j <= t] >= 0  # energy reserve dn
        ERESUPDIS[S, j in T, t in T; j <= t] >= 0 # energy reserve up discharging
        ERESUPCH[S, j in T, t in T; j <= t] >= 0 # energy reserve up charging
        ERESDNCH[S, j in T, t in T; j <= t] >= 0 # energy reserve dn from charging
        ERESDNDIS[S, j in T, t in T; j <= t] >= 0 # energy reserve dn from discharging
    end)

    @variables(model, begin
        ESOEUP[S, j in T_incr, t in T_incr; j <= t] >= 0
        ESOEDN[S, j in T_incr, t in T_incr; j <= t] >= 0
    end)
    @variables(model, begin
        MAXERESUPDIS[S,T] >= 0  #auxiliary variable: maximum energy reserve from discharging up
        MAXERESUPCH[S,T] >= 0 #auxiliary variable 
        MAXERESDNCH[S,T] >= 0 #auxiliary variable 
        MAXERESDNDIS[S,T] >= 0 #auxiliary variable 
    end)

    @variables(model, begin
        εUPDIS[S,T] >= 0 #epsilon tracks deviation from energy reserves and auxiliary variable
        εUPCH[S,T] >= 0
        εDNCH[S,T] >= 0
        εDNDIS[S,T] >= 0
    end)

    @variables(model, begin
        θUPDIS[S,T] >= 0  #output of this model we want to use as  it should be multiplier up multiplied by power reserve up from discharging
        θUPCH[S,T] >= 0  #output of this model 
        θDNCH[S,T] >= 0 
        θDNDIS[S,T] >= 0 
    end)

    @constraint(model, θ_ε_UpDis[s in S, t in T],
        θUPDIS[s,t] <= RESUPDIS[s,t] #meaning multiplier lower or equal to 1
    )
    @constraint(model, θ_ε_UpCh[s in S, t in T],
        θUPCH[s,t] <= RESUPCH[s,t] #meaning multiplier lower or equal to 1
    )
    @constraint(model, θ_ε_DnDis[s in S, t in T],
        θDNDIS[s,t] <= RESDNDIS[s,t] #meaning multiplier lower or equal to 1
    )
    @constraint(model, θ_ε_DnCh[s in S, t in T],
        θDNCH[s,t] <= RESDNCH[s,t] #meaning multiplier lower or equal to 1
    )

    # Envelopes initial conditions
  #  @constraint(model, SOEUP_0[s in S],
  #      SOEUP[s,T_incr[1]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )
  #  @constraint(model, SOEDN_0[s in S],
  #      SOEDN[s,T_incr[1]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )

    # Envelopes max and min 
    # SOEUP, SOEDN <=SOE_max
  #  @constraint(model, SOEUPMax[s in S, t in T],
  #      SOEUP[s,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )
  #  @constraint(model, SOEDNMax[s in S, t in T],
  #      SOEDN[s,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )
    # SOEUP, SOEDN>=SOE_min
  #  @constraint(model, SOEUPMin[s in S, t in T],
  #      SOEUP[s,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
  #   )
  #  @constraint(model, SOEDNMin[s in S, t in T],
  #      SOEDN[s,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
  #  )

    # Envelopes time evolution
   # @constraint(model, SOEUpEvol[s in S, t in T],
  #      SOEUP[s,t]  == SOEUP[s,t-1] + RESDNCH[s,t]*ηch[s] + RESDNDIS[s,t]/ηdis[s]
  #  ) 
  #  @constraint(model, SOEDnEvol[s in S, t in T], 
  #      SOEDN[s,t]  == SOEDN[s,t-1] - RESUPCH[s,t]*ηch[s] - RESUPDIS[s,t]/ηdis[s]
  #  )

    # @constraint(model, SOEUpEvol[s in S, t in T],
    #     SOEUP[s,t]  == SOEUP[s,t-1] + θDNCH[s,t]*ηch[s] + θDNDIS[s,t]/ηdis[s]
    # ) 
    # @constraint(model, SOEDnEvol[s in S, t in T], 
    #     SOEDN[s,t]  == SOEDN[s,t-1] - θUPCH[s,t]*ηch[s] - θUPDIS[s,t]/ηdis[s]
    # )


    # Reserves addition
    @constraint(model, ResUpStorageCapacityMax[s in S, t in T],
        RESUP[s,t] == RESUPDIS[s,t] + RESUPCH[s,t]
    )
    @constraint(model, ResDownStorageCapacityMax[s in S, t in T],
        RESDN[s,t] == RESDNCH[s,t] + RESDNDIS[s,t]
    )
    # Reserve requirements
    @constraint(model, ResUpRequirement[t in T],
        sum(RESUP[g,t] for g in S) == reserve[reserve.hour .== t,:reserve_up_MW][1]
    )
    @constraint(model, ResDnRequirement[t in T],
        sum(RESDN[g,t] for g in S) == reserve[reserve.hour .== t,:reserve_down_MW][1]
    )

    # E-envelopes initial conditions
    # ESOEUP[T_initial,T_initial] = SOE[T_initial]
  #  @constraint(model, ESOEUP_0[s in S, t in T_incr],
  #      ESOEUP[s,T_incr[1],T_incr[1]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )
    # ESOEDN[T_initial,T_initial] = SOE[T_initial]
  #  @constraint(model, ESOEDN_0[s in S, t in T_incr],
  #      ESOEDN[s,T_incr[1], T_incr[1]] == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1]
  #  )
  #  @constraint(model, ESOEUPEvol_0[s in S, t in T],
  #      ESOEUP[s,T_incr[1],t] == ESOEUP[s,T[1],t]
  #  )
  #  @constraint(model, ESOEDNEvol_0[s in S, t in T],
  #      ESOEDN[s,T_incr[1],t] == ESOEDN[s,T[1],t]
  #  )

    # SOEUP, SOEDN <=SOE_max
 #   @constraint(model, ESOEUPMax[s in S, j in T, t in T; j <= t],
 #       ESOEUP[s,j,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
 #   )
  #  @constraint(model, ESOEDNMax[s in S, j in T, t in T; j <= t],
 #       ESOEDN[s,j,t] <= storage[storage.r_id .== s,:max_energy_mwh][1]
 #   )
  #  # SOEUP, SOEDN>=SOE_min
 #   @constraint(model, ESOEUPMin[s in S, j in T, t in T; j <= t],
  #      ESOEUP[s,j,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
  #  )
 #   @constraint(model, ESOEDNMin[s in S, j in T, t in T; j <= t],
 #       ESOEDN[s,j,t] >= storage[storage.r_id .== s,:min_energy_mwh][1]
 #   )

    # e-envelopes evolution
#    @constraint(model, ESOEUpEvol[s in S, j in T, t in T; j <= t],
 #       ESOEUP[s,j,t]  == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1] + ERESDNCH[s,j,t]*ηch[s] + ERESDNDIS[s,j,t]/ηdis[s]
  #  )
 #   @constraint(model, ESOEDnEvol[s in S, j in T, t in T; j <= t], 
 #       ESOEDN[s,j,t]  == storage[storage.r_id .== s,:initial_energy_proportion][1]*storage[storage.r_id .== s,:max_energy_mwh][1] - ERESUPCH[s,j,t]*ηch[s] - ERESUPDIS[s,j,t]/ηdis[s]
 #   )

    # e-reserve addition
    @constraint(model, EnergyResUpStorage[s in S, j in T, t in T; j <= t],
        ERESUP[s,j,t] == ERESUPDIS[s,j,t] + ERESUPCH[s,j,t]
    )
    @constraint(model, EnergyResDownStorage[s in S, j in T, t in T; j <= t],
        ERESDN[s,j,t] == ERESDNCH[s,j,t] + ERESDNDIS[s,j,t]
    )

    # e-reserve requirements
    @constraint(model, EnergyResUpRequirement[j in T, t in T; j <= t],
        sum(ERESUP[i, j, t] for i in S) == energy_reserve[(energy_reserve.i_hour .== j).&(energy_reserve.t_hour .== t),:reserve_up_MW][1]
    )
 
    @constraint(model, EnergyResDnRequirement[j in T, t in T; j <= t],
        sum(ERESDN[i, j, t] for i in S) == energy_reserve[(energy_reserve.i_hour .== j).&(energy_reserve.t_hour .== t),:reserve_down_MW][1]
    )
    

    @constraint(model, EnergyResUpDisMin[s in S, j in T, t in T; j <= t],
        MAXERESUPDIS[s,t] >= ERESUPDIS[s,j,t] #auxiliary variable aims to find the 'worst' energy reserve impact from any starting time j to time t
    )
    @constraint(model, EnergyResUpChMin[s in S, j in T, t in T; j <= t],
        MAXERESUPCH[s,t] >= ERESUPCH[s,j,t]
    )
    @constraint(model, EnergyResDnDisMin[s in S, j in T, t in T; j <= t],
        MAXERESDNDIS[s,t] >= ERESDNDIS[s,j,t]
    )
    @constraint(model, EnergyResDnChMin[s in S, j in T, t in T; j <= t],
        MAXERESDNCH[s,t] >= ERESDNCH[s,j,t]
    )


    @constraint(model, EpsilonsDnChMin[s in S, t in T],
        εDNCH[s,t] == sum(θDNCH[s,j]*ηch[s] for j in T if j<=t) - MAXERESDNCH[s,t]*ηch[s]  #this is deviation between output and maximum energy reserve impact
    )
    @constraint(model, EpsilonsDnDisMin[s in S, t in T],
        εDNDIS[s,t] == sum(θDNDIS[s,j]/ηdis[s] for j in T if j<=t) - MAXERESDNDIS[s,t]/ηdis[s]
    )
    @constraint(model, EpsilonsUpChMin[s in S, t in T],
        εUPCH[s,t] == sum(θUPCH[s,j]*ηch[s] for j in T if j<=t) - MAXERESUPCH[s,t]*ηch[s]
    )
    @constraint(model, EpsilonsUpDisMin[s in S, t in T],
        εUPDIS[s,t] == sum(θUPDIS[s,j]/ηdis[s] for j in T if j<=t) - MAXERESUPDIS[s,t]/ηdis[s]
    )


   # @constraint(model, EpsilonsDnChMinIneq[s in S, t in T],
   #    sum(θDNCH[s,j]*ηch[s] for j in T if j<=t) >= MAXERESDNCH[s,t]
   # )
   # @constraint(model, EpsilonsDnDisMinIneq[s in S, t in T],
   #     sum(θDNDIS[s,j]/ηdis[s] for j in T if j<=t) >= MAXERESDNDIS[s,t]
   # )
   # @constraint(model, EpsilonsUpChMinIneq[s in S, t in T],
   #     sum(θUPCH[s,j]*ηch[s] for j in T if j<=t) >= MAXERESUPCH[s,t]
   # )
   # @constraint(model, EpsilonsUpDisMinIneq[s in S, t in T],
   #     sum(θUPDIS[s,j]/ηdis[s] for j in T if j<=t) >= MAXERESUPDIS[s,t]
   # )

#  Power constraints 
    # @constraint(model, EnergyResUpStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
    #     ERESUPDIS[s,j,t] <= sum(
    #         RESUPDIS[s,tt] for tt in T if (tt >= j)&(tt <= t)
    #     )
    # )
    # @constraint(model, EnergyResUpStorageChCapacityMax[s in S, j in T, t in T; j <= t],
    #     ERESUPCH[s,j,t] <= sum(
    #         RESUPCH[s,tt] for tt in T if (tt >= j)&(tt <= t)
    #     )
    # )
    # @constraint(model, EnergyResDownStorageChCapacityMax[s in S, j in T, t in T; j <= t],
    #     ERESDNCH[s,j,t] <= sum(
    #         RESDNCH[s,tt] for tt in T if (tt >= j)&(tt <= t)
    #     )
    # )
    # @constraint(model, EnergyResDownStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
    #     ERESDNDIS[s,j,t] <= sum(
    #         RESDNDIS[s,tt] for tt in T if (tt >= j)&(tt <= t)
    #     )
    # )

    @expression(model, epsilon_variance,
        sum(εDNCH[s,t]^2 +  εDNDIS[s,t]^2 + εUPCH[s,t]^2 + εUPDIS[s,t]^2 for s in S for t in T)
    )
    @expression(model, theta,
       sum(θDNCH[s,t] + θDNDIS[s,t] + θUPCH[s,t] + θUPDIS[s,t] for s in S for t in T)
    )
    @expression(model, reserve,
       sum(RESDNCH[s,t] + RESDNDIS[s,t] + RESUPCH[s,t] + RESUPDIS[s,t] for s in S for t in T)
    )
    @expression(model, theta_variance, # not used
       sum(θDNCH[s,t]^2 + θDNDIS[s,t]^2 + θUPCH[s,t]^2 + θUPDIS[s,t]^2 for s in S for t in T)
    )
    @expression(model, reserve_variance, # not used
       sum(RESDNCH[s,t]^2 + RESDNDIS[s,t]^2 + RESUPCH[s,t]^2 + RESUPDIS[s,t]^2 for s in S for t in T)
    )
    @objective(model, Min,
        model[:epsilon_variance] + model[:theta] - model[:reserve]
    )
   
    return model
end

function solve_empirical_µ_get_solution(gen_df, loads, storage, reserve, required_energy_reserve)
    variables_to_save = [:θDNCH, :θDNDIS, :θUPCH, :θUPDIS, :RESDNCH, :RESDNDIS, :RESUPCH, :RESUPDIS]
    model = construct_empirical_µ(gen_df, loads, storage, reserve, required_energy_reserve)
    optimize!(model)
    out = Dict(Symbol(var) => DataFrame(Containers.rowtable(value.(model[var]); header = [:r_id, :t, :value])) for var in variables_to_save if haskey(model, var))
    return out
end
