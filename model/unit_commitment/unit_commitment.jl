using DataFrames
include("./deterministic.jl")
include("./stochastic.jl")
include("./config.jl")

function construct_deterministic_unit_commitment(gen_df, mip_gap, storage, ramp_constraints; kwargs...)
    println("Constructing DUC...")
    reserve = get(kwargs, :reserve, g_reserve)
    energy_reserve = get(kwargs, :energy_reserve, g_energy_reserve)
    storage_envelopes = get(kwargs, :storage_envelopes, g_storage_envelopes)
    storage_link_constraint =  get(kwargs, :storage_link_constraint, g_storage_link_constraint)
    storage_reserve_repartition =  get(kwargs, :storage_reserve_repartition, g_storage_reserve_repartition) 
    VRESERVE = get(kwargs, :VRESERVE, g_VRESERVE)
    VSRESUP = get(kwargs, :VSRESUP, g_VSRESUP)
    VSRESDN = get(kwargs, :VSRESDN, g_VRESDN)
    bidirectional_storage_reserve = get(kwargs, :bidirectional_storage_reserve, g_bidirectional_storage_reserve)
    thermal_reserve = get(kwargs, :thermal_reserve, g_thermal_reserve)
    naive_envelopes = get(kwargs, :naive_envelopes, g_naive_envelopes)

    sets =  get_sets(gen_df)

    uc = DUC(gen_df, mip_gap)
    
    if !isnothing(storage)
        println("Adding storage...")
        add_storage(uc, storage, sets)
    end
    if ramp_constraints
        println("Adding ramp constraints...")   
        add_ramp_constraints(uc, gen_df, sets)
    end
    if reserve
        println("Adding reserve constraints...")
        add_reserve_constraints(uc, gen_df, storage, bidirectional_storage_reserve, storage_envelopes, naive_envelopes, thermal_reserve, storage_reserve_repartition, VRESERVE, VSRESUP, VSRESDN, sets)
    end
    if energy_reserve
        println("Adding energy reserve constraints...")
        add_energy_reserve_constraints(uc, gen_df, storage, storage_envelopes, storage_link_constraint, thermal_reserve, VRESERVE, VSRESUP, VSRESDN, sets)
    end
    return uc
end


function construct_stochastic_unit_commitment(gen_df, gen_variable, mip_gap, storage, ramp_constraints, scenarios, expected_min_SOE, VLOL, VLGEN)
    println("Constructing SUC...")
    uc = SUC(gen_df, gen_variable, scenarios, mip_gap, VLOL, VLGEN)
    if !isnothing(storage)
        println("Adding storage...")
        add_storage_s(uc, storage, scenarios, get_sets(gen_df, scenarios.probability), expected_min_SOE) # TODO: This function is meant to be used within SUC
    end
    if ramp_constraints
        println("Adding ramp constraints...")   
        add_ramp_constraints_s(uc, gen_df, get_sets(gen_df, scenarios.probability)) # TODO: This function is meant to be used within SUC
    end
    return uc
end

function update_daily_data(model, loads, gen_variable, storage, μ_up, μ_dn, required_reserve, required_energy_reserve, energy_reserve)
    # Updates the deterministic unit commitment model with new loads, gen_variable, reserve and energy_reserve
    println("Updating DUC model with time-dependent data...")
    # update_loads(model, loads)
    # update_gen_variable(model, gen_variable)
    update_parameter_value(model, :p_MAX_GEN, convert_to_matrix(gen_variable, :r_id, :hour, :max_production_mw))
    update_parameter_value(model, :p_DEMAND, loads[:,:demand])
    # update_parameter_value(model, :p_μ_UP, μ_up)
    # update_parameter_value(model, :p_μ_DN, μ_dn)
    if !energy_reserve
        set_envelope_multipliers(model, μ_up, μ_dn, storage)
        update_parameter_value(model, :RRESUP, required_reserve[:,:reserve_up_MW])
        update_parameter_value(model, :RRESDN, required_reserve[:,:reserve_down_MW])
    else
        set_energy_envelope_multipliers(model, μ_up, μ_dn, storage)
        update_parameter_value(model, :RERESUP, convert_to_matrix(required_energy_reserve, :i_hour, :t_hour, :reserve_up_MW))
        update_parameter_value(model, :RERESDN, convert_to_matrix(required_energy_reserve, :i_hour, :t_hour, :reserve_down_MW))
    end
    println("...done")
    return model
end 


function construct_unit_commitment(gen_df; scenarios, kwargs...)
    storage = get(kwargs, :storage, g_storage)
    ramp_constraints = get(kwargs, :ramp_constraints, g_ramp_constraints)
    mip_gap = get(kwargs, :mip_gap, g_mip_gap)
    expected_min_SOE = get(kwargs, :expected_min_SOE, g_expected_min_SOE)
    VLOL = get(kwargs, :VLOL, g_VLOL)
    VLGEN = get(kwargs, :VLGEN, g_VLGEN)
    if isnothing(scenarios)
        return construct_deterministic_unit_commitment(gen_df, mip_gap, storage, ramp_constraints; kwargs...)
    else
        return construct_stochastic_unit_commitment(gen_df, gen_variable, mip_gap, storage, ramp_constraints, scenarios, expected_min_SOE, VLOL, VLGEN)
    end
end


