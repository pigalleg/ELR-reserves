using JuMP
using Gurobi
include("../unit_commitment/utils.jl")
include("../pre_processing.jl")

function construct_empirical_µ(gen_df,  loads, storage, reserve, energy_reserve, temportal_weights, mip_gap = 1e-6)
    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "MIPGap", mip_gap)
    sets = get_sets(gen_df, loads)
    T = sets.T

    T_incr = copy(T)
    pushfirst!(T_incr, T_incr[1]-1) # T_incr = [t[1]-1,T]
    S = create_storage_sets(storage)
    # ATTENTION: next line is ofr testing
    S = [S[1]]
    ηch = Dict(s => storage[storage.r_id .== s,:charge_efficiency][1] for s in S)
    ηdis = Dict(s => storage[storage.r_id .== s,:discharge_efficiency][1] for s in S)
    if temportal_weights
        ω = Dict(T .=> reverse(1:length(T))) # weight fror penalizing difference between θ and RES in objective function as a function of time
    else
        ω = Dict(T .=> 1)
    end 

    @variables(model, begin
        RESUP[S,T] >= 0 # power reseve up
        RESDN[S,T] >= 0 # power reserve down
        RESUPDIS[S,T]>= 0 # power reserve up from discharging 
        RESUPCH[S,T]>= 0 # power reserve up from charging
        RESDNCH[S,T]>= 0 # power reserve dn fromcharging
        RESDNDIS[S,T]>= 0 # power reserve dn from discharging#
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
        εDNCH[s,t] == sum(θDNCH[s,j]*ηch[s] for j in T if j<=t) - (MAXERESDNCH[s,t])*ηch[s]  #this is deviation between output and maximum energy reserve impact
    )
    @constraint(model, EpsilonsDnDisMin[s in S, t in T],
        εDNDIS[s,t] == sum(θDNDIS[s,j]/ηdis[s] for j in T if j<=t) - (MAXERESDNDIS[s,t])/ηdis[s]
    )
    @constraint(model, EpsilonsUpChMin[s in S, t in T],
        εUPCH[s,t] == sum(θUPCH[s,j]*ηch[s] for j in T if j<=t) - (MAXERESUPCH[s,t])*ηch[s]
    )
    @constraint(model, EpsilonsUpDisMin[s in S, t in T],
        εUPDIS[s,t] == sum(θUPDIS[s,j]/ηdis[s] for j in T if j<=t) - (MAXERESUPDIS[s,t])/ηdis[s]
    )
    

#  Power constraints 
    @constraint(model, EnergyResUpStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
        ERESUPDIS[s,j,t] <= sum(
            RESUPDIS[s,tt] for tt in T if (tt >= j)&(tt <= t) # ATTENTION slack variable removed: - sUPDIS[s,j,t]
        )
    )
    @constraint(model, EnergyResUpStorageChCapacityMax[s in S, j in T, t in T; j <= t],
        ERESUPCH[s,j,t] <= sum(
            RESUPCH[s,tt] for tt in T if (tt >= j)&(tt <= t) # ATTENTION slack variable removed sUPCH[s,j,t]
        )
    )
    @constraint(model, EnergyResDownStorageChCapacityMax[s in S, j in T, t in T; j <= t],
        ERESDNCH[s,j,t] <= sum(
            RESDNCH[s,tt] for tt in T if (tt >= j)&(tt <= t) # ATTENTION slack variable removed: sDNCH[s,j,t]
        )
    )
    @constraint(model, EnergyResDownStorageDisCapacityMax[s in S, j in T, t in T; j <= t],
        ERESDNDIS[s,j,t] <= sum(
            RESDNDIS[s,tt] for tt in T if (tt >= j)&(tt <= t) # ATTENTION slack variable removed: sDNDIS[s,j,t]
        )
    )

    @expression(model, epsilon_variance,
        sum(εDNCH[s,t]^2 +  εDNDIS[s,t]^2 + εUPCH[s,t]^2 + εUPDIS[s,t]^2 for s in S for t in T)
    )
    @expression(model, theta,
       sum(ω[t]*(θDNCH[s,t] + θDNDIS[s,t] + θUPCH[s,t] + θUPDIS[s,t]) for s in S for t in T) 
    )
    @expression(model, reserve,
       sum(ω[t]*(RESDNCH[s,t] + RESDNDIS[s,t] + RESUPCH[s,t] + RESUPDIS[s,t]) for s in S for t in T)
    )

    @objective(model, Min,
        model[:epsilon_variance] + (model[:theta] - model[:reserve])# + model[:slack]
    )
   
    return model
end

function solve_empirical_µ_get_solution(gen_df, loads, storage, required_reserve, required_energy_reserve; temportal_weights = false)
    function rename_headers(df, var)
        if size(df, 2) == 4
            keys_to_rename = Dict(:x1 => :r_id, :x2 => :i, :x3 => :t, :y => Symbol(var))
        elseif size(df, 2) == 3
            keys_to_rename = Dict(:x1 => :r_id, :x2 => :t, :y => Symbol(var))
        else
            keys_to_rename = Dict(:x1 => :r_id, :y => Symbol(var))
        end 
        return rename(df, keys_to_rename)
    end

    model = construct_empirical_µ(gen_df, loads, storage, required_reserve, required_energy_reserve, temportal_weights)
    optimize!(model)
    variables_to_save = [
        :RESUP, :RESDN, :RESUPDIS, :RESUPCH, :RESDNCH, :RESDNDIS,
        :SOEUP, :SOEDN,
        :ERESUP, :ERESDN, :ERESUPDIS, :ERESUPCH, :ERESDNCH, :ERESDNDIS,
        :ESOEUP, :ESOEDN,
        :MAXERESUPDIS, :MAXERESUPCH, :MAXERESDNCH, :MAXERESDNDIS,
        :εUPDIS, :εUPCH, :εDNCH, :εDNDIS,
        :θUPDIS, :θUPCH, :θDNCH, :θDNDIS,
        # :sUPDIS, :sUPCH, :sDNCH, :sDNDIS
    ]
    out = [rename_headers(DataFrame(Containers.rowtable(value.(model[var]))), var) for var in variables_to_save if haskey(model, var)]
    out_with_headers_i = [df for df in out if :i in Symbol.(names(df))] # out with header :i
    out_rest = setdiff(out, out_with_headers_i)
    out_left = reduce((df1, df2) -> outerjoin(df1, df2, on = [:r_id, :t]), out_rest)
    out_right = reduce((df1, df2) -> outerjoin(df1, df2, on = [:r_id, :i, :t]), out_with_headers_i)
    return model, out_left, out_right

end

function calculate_mu_t(sol_1_)
    sol_1 = dropmissing(sol_1_)
    mu = DataFrame()
    for (θ, RES) in [(:θUPDIS, :RESUPDIS), (:θUPCH, :RESUPCH), (:θDNDIS, :RESDNDIS), (:θDNCH, :RESDNCH)]
        # mu[!, Symbol("$θ/$RES")] = cumsum(sol_1[:, θ]) ./ cumsum(sol_1[:, RES]) # comment this to get cumulative ratio
        mu[!, Symbol("$θ/$RES")] = (sol_1[:, θ]) ./ (sol_1[:, RES])
    end
    mu = insertcols(mu, 1, :t => sol_1.t)
    mu = mu[1:end, :]
    leftjoin!(sol_1, mu, on = :t)
    return coalesce.(mu, 0.0)
    # return unstack(stack(mu, Not(:t), variable_name=:mu),:t, :value)
end

function main(input_folder = "../../input/RTS-GMLC_v1.0") # This function has been checked that yelds the right values
    days = range(1,7)
    temportal_weights = false
    mu_t_all = DataFrame()
    for day in days
        gen_df, loads_df, random_loads_df, gen_variable_df, storage_df,  = generate_deterministic_input_data(day, input_folder)
        required_reserve = filter_day(day, CSV.read(joinpath(input_folder, G_UC_DATA, "Reserve.csv"), DataFrame))
        required_energy_reserve =  filter_day(day, CSV.read(joinpath(input_folder, G_UC_DATA, "Energy reserve.csv"), DataFrame))
        model, sol_1, sol_2 = solve_empirical_µ_get_solution(gen_df, loads_df, storage_df, required_reserve, required_energy_reserve; temportal_weights = temportal_weights)
        mu_t = calculate_mu_t(sol_1)
        # mu_t = insertcols(mu_t, 1, :rho => rho)
        mu_t = insertcols(mu_t, 1, :day => day)
        append!(mu_t_all, mu_t)
    end
    mu_t_all = insertcols(mu_t_all, 1, :input_folder => split(input_folder, "input/")[end])
    CSV.write("empirical_mu.csv", mu_t_all)

end