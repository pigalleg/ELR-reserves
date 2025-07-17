function add_envelopes_UC(model)
    #TODO :extend to energy enevelopes
    # UC envelopes
    if haskey(model, :SOEUP)
        @expression(model, SOEUP_UC, value.(model[:SOEUP]))
        @expression(model, SOEDN_UC, value.(model[:SOEDN]))
    elseif  haskey(model, :ESOEUP)
        @expression(model, ESOEUP_UC, value.(model[:ESOEUP]))
        @expression(model, ESOEDN_UC, value.(model[:ESOEDN]))
    end
end

function add_envelopes_ED(model, E_SOEUP_value, E_SOEDN_value)
    # ED envelopes
    if haskey(model, :SOEUP)
        remove_variable_constraint(model, :SOEUP)
        @expression(model, SOEUP, E_SOEUP_value)
        remove_variable_constraint(model, :SOEDN)
        @expression(model, SOEDN, E_SOEDN_value)
    elseif haskey(model, :ESOEUP)
        remove_variable_constraint(model, :ESOEUP)
        @expression(model, ESOEUP, E_SOEUP_value)
        remove_variable_constraint(model, :ESOEDN)
        @expression(model, ESOEDN, E_SOEDN_value)
    end
end

function generate_envelopes(model)
    function generate_envelopes()
        RESDNCH = model[:RESDNCH]
        RESDNDIS = model[:RESDNDIS]
        RESUPCH = model[:RESUPCH]
        RESUPDIS = model[:RESUPDIS]
        # SOEPUP_value = +Array(value.(CH)).*η_ch + (Array(value.(RESDNCH)).*η_ch + Array(value.(RESDNDIS)).*inv_η_dis).* μ_dn' # approach 3
        # SOEPUP_value = hcat(zeros(1,size(SOEPUP_value)[1])', SOEPUP_value) # For T[1]-1 no reserves are activated
        # SOEPUP_value = [value(SOE[s,T_incr[1]]) for s in S, t in T_incr] + cumsum(SOEPUP_value; dims = 2)
        SOEPUP_value = (Array(value.(RESDNCH)).*η_ch + Array(value.(RESDNDIS)).*inv_η_dis)#.*μ_dn' #approach 1&2
        SOEPUP_value = hcat(zeros(1,size(SOEPUP_value)[1])', SOEPUP_value) #  #approach 1&2
        SOEPUP_value = Array(value.(SOE)) + cumsum(SOEPUP_value; dims = 2) # approach 1
        # SOEPUP_value = [value(SOE[s,T_incr[1]]) for s in S, t in T_incr] + cumsum(SOEPUP_value; dims = 2) # approach 2

        # SOEPDN_value = -Array(value.(DIS)).*inv_η_dis -(Array(value.(RESUPCH)).*η_ch + Array(value.(RESUPDIS)).*inv_η_dis).* μ_up'# approach 3
        # SOEPDN_value = hcat(zeros(1,size(SOEPDN_value)[1])', SOEPDN_value)
        # SOEPDN_value = [value(SOE[s,T_incr[1]]) for s in S, t in T_incr] + cumsum(SOEPDN_value; dims = 2)

        SOEPDN_value = -(Array(value.(RESUPCH)).*η_ch + Array(value.(RESUPDIS)).*inv_η_dis)#.* μ_up' #approach 1&2
        SOEPDN_value = hcat(zeros(1,size(SOEPDN_value)[1])', SOEPDN_value) # approach 1&2
        SOEPDN_value = Array(value.(SOE))  + cumsum(SOEPDN_value; dims = 2) # approach 1
        # SOEPDN_value = [value(SOE[s,T_incr[1]]) for s in S, t in T_incr] + cumsum(SOEPDN_value; dims = 2) # approach 2

        SOEMax_value = hcat(Array(normalized_rhs.(model[:SOEMax]))[:,1], Array(normalized_rhs.(model[:SOEMax]))) # adding extra column for T[1]-1
        SOEMin_value = hcat(Array(normalized_rhs.(model[:SOEMin]))[:,1], Array(normalized_rhs.(model[:SOEMin])))
        
        SOEPUP_value = min.(SOEPUP_value, SOEMax_value)
        SOEPDN_value = max.(SOEPDN_value, SOEMin_value)
        return Containers.DenseAxisArray(SOEPUP_value, S, T_incr), Containers.DenseAxisArray(SOEPDN_value, S, T_incr)
    end

    function generate_energy_envelopes()
        #TODO: this function differs from previous one as it does not recalculate the envelopes. It would be good to harmonize....
        return value.(model[:ESOEUP]), value.(model[:ESOEDN])
    end
    CH = model[:CH]
    DIS = model[:DIS]
    S = axes(CH)[1]
    T = axes(CH)[2]
    SOE = model[:SOE]
    T_incr = axes(SOE)[2]

    SOE_constraint_list = [constraint_object.(model[:SOEEvol][s,T[1]]).func for s in S]
    η_ch =-map(coefficient, SOE_constraint_list, Array(CH[:,T[1]]))
    inv_η_dis = map(coefficient, SOE_constraint_list, Array(DIS[:,T[1]]))
    if haskey(model, :SOEUP)
        μ_up, μ_dn = get_multipliers(model)
        return  generate_envelopes()
    else
        return generate_energy_envelopes()
    end
end

function update_demand(model, loads, key = DEMAND)
    # Update demand values and introduces LOL at supply-demand balance
    T, __ = create_time_sets()
    LOL = model[LOL_]

    if haskey(model, :LOLMax) remove_variable_constraint(model, :LOLMax) end
    @constraint(model, LOLMax[t in T],
        LOL[t]<= loads[loads.hour .== t, key][1]    
    )

    SupplyDemand = model[:SupplyDemand]
    remove_variable_constraint(model, :SupplyDemandBalance)
    @constraint(model, SupplyDemandBalance[t in T], 
        SupplyDemand[t] == loads[loads.hour .== t, key][1]
    )
end

function update_generation(model, gen_variable)
    remove_variable_constraint(model, :Cap_var)
    GEN = model[:GEN]
    @constraint(model, Cap_var[i in 1:nrow(gen_variable)], 
        GEN[gen_variable[i,:r_id], gen_variable[i,:hour] ] <= gen_variable[i,:cf]*gen_variable[i,:existing_cap_mw]
    )
end
    
function get_multipliers(model)
    CH = model[:CH]
    DIS = model[:DIS]
    RESDNCH = model[:RESDNCH]
    RESUPCH = model[:RESUPCH]
    S = axes(CH)[1]
    T = axes(CH)[2]

    SOE_constraint_list = [constraint_object.(model[:SOEEvol][s,T[1]]).func for s in S]
    η_ch = -map(coefficient, SOE_constraint_list, Array(CH[:,T[1]]))
    
    # We assume that μ=μ(t), but independent of storage unit. We use therefore the first storage to determine the value: η_ch[1]
    SOEUp_constraint_list  = [constraint_object.(model[:SOEUpEvol][S[1],t]).func for t in T]
    μ_dn = -map(coefficient, SOEUp_constraint_list, Array(RESDNCH[S[1],:]))/η_ch[1]
    SOEDN_constraint_list  = [constraint_object.(model[:SOEDnEvol][S[1],t]).func for t in T]
    μ_up = map(coefficient, SOEDN_constraint_list, Array(RESUPCH[S[1],:]))./η_ch[1]
    
    return μ_up, μ_dn
end