using DataFrames
using Statistics
using Parquet2


# parse_configuration_to_mu(x) = !isnothing(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))) ? parse(Float64, replace(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))[1], "_" => ".")) : 1
g_NET_GENERATION_FULL_ID = "net_generation"
g_SYSTEM_ID = "system"

function parse_configuration_to_mu(x::String)
    expr_1 = r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)"
    expr_2 = r"base_ramp_storage_envelopes_(\w+)"
    if occursin(expr_1, x)
        return parse(Float64, replace(match(expr_1, x)[1], "_" => "."))
    elseif occursin(expr_2, x)
        return match(expr_2, x)[1]
    else
        return nothing
    end
end

function calculate_adecuacy_gcdi_KPI(s_ed, s_uc = nothing)
    # if stochastic, s_ed = s_suc and s_uc = nothing
    function calculate_basic_KPI(s_ed, group_by)
        thres = 0.001
        f_LOL(x, y) = (
            LLD_h = count(>(thres), x),
            ENS_MWh = sum(x),
            input_load_MWh = sum(y) + sum(x) # input_load = production + LOL. Input demand can be different from input file because of capping for reserves
        )
        f_CUR(x, y) = (
            CURD_h = count(>(thres), x),
            CUR_MWh = sum(x),
            input_RES_production_MWh = sum(y) + sum(x) # input_RES_production = RES_production + CUR
        )
        f_storage(x,y) = (
            storage_charge_MWh = sum(skipmissing(x)),
            storage_discharge_MWh = sum(skipmissing(y)),
            storage_net_charge_MWh = sum(skipmissing(x))-sum(skipmissing(y))
        )
        function calculate_ΔSOE(s_ed)
            s_ed_storage_last = s_ed.storage[s_ed.storage.hour .== maximum(s_ed.storage.hour), :]
            SOE_0 = combine(groupby(s_ed.storage_parameters, intersect(group_by, propertynames(s_ed.storage_parameters))), [:initial_energy_proportion,:SOE_max_MWh] => ((x,y) -> sum(x.*y)) => :SOE_0_MWh)
            ΔSOE = combine(groupby(s_ed_storage_last, group_by), :SOE_MWh => (x->sum(skipmissing(x))) => :SOE_T_MWh)
            ΔSOE.SOE_0_MWh .= unique(SOE_0.SOE_0_MWh)
            # leftjoin!(ΔSOE, SOE_0,on = intersect(group_by, propertynames(SOE_0)))
            ΔSOE.net_SOE_MWh = ΔSOE.SOE_T_MWh .- ΔSOE.SOE_0_MWh
            return ΔSOE
        end

        var_filter = s_ed.generation.r_id .∈ Ref(s_ed.generation_parameters[s_ed.generation_parameters.is_var,:r_id])
        thermal_filter = s_ed.generation.r_id .∈ Ref(s_ed.generation_parameters[s_ed.generation_parameters.is_thermal,:r_id])
        nt_nonvar_filter = .!var_filter .& .!thermal_filter
        out = outerjoin(
            combine(groupby(s_ed.demand, group_by), [:LOL_MW, :demand_MW] => ((x, y) -> f_LOL(x, y)) => AsTable),
            combine(groupby(s_ed.generation[var_filter, :], group_by), [:curtailment_MW, :production_MW] => ((x, y) -> f_CUR(x, y)) => AsTable),
            combine(groupby(s_ed.generation[thermal_filter, :], group_by), :production_MW => sum => :thermal_production_MWh),
            combine(groupby(s_ed.generation[nt_nonvar_filter, :], group_by), :production_MW => sum => :nonRES_nonThermal_production_MWh),
            combine(groupby(s_ed.storage, group_by), [:charge_MW,:discharge_MW] => ((x, y) -> f_storage(x, y)) => AsTable),
            on = group_by
        )
        leftjoin!(out, calculate_ΔSOE(s_ed), on = group_by)
        if :LGEN_MW in propertynames(s_ed.demand)
            out = outerjoin(out, combine(groupby(s_ed.demand, group_by), :LGEN_MW => sum => :LGEN_MWh), on = group_by)
        end
        if :slack_SOE_final_MWh in propertynames(s_ed.storage)
            out = outerjoin(out, combine(groupby(s_ed.storage, group_by), :slack_SOE_final_MWh => (x->sum(skipmissing(x))) => :slack_SOE_final_MWh), on = group_by)
        end
        return out
    end

    function calculate_uc_KPI(s_uc, group_by) #TODO: move it to calculate_adecuacy_gcd_KPI()
        function filter_diagonal_terms(df)
            if :hour_i in propertynames(df) # this allows to sum only diagonal terms of the reserve matrix
                return df[df.hour .== df.hour_i, :]
            else
                return df
            end
        end
        var_filter = s_uc.generation.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_var,:r_id])
        thermal_filter = s_uc.generation.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_thermal,:r_id])
        nt_nonvar_filter = .!var_filter .& .!thermal_filter
        out = outerjoin(
            combine(groupby(s_uc.demand, group_by), [:demand_MW, :LGEN_MW, :LOL_MW] .=> sum .=> [:input_load_uc_MWh, :LGEN_uc_MWh, :LOL_uc_MWh]),
            combine(groupby(s_uc.generation[var_filter, :], group_by), :production_MW => sum => :input_RES_production_uc_MWh),
            combine(groupby(s_uc.generation[thermal_filter, :], group_by), :production_MW => sum => :thermal_production_uc_MWh),
            combine(groupby(s_uc.generation[nt_nonvar_filter, :], group_by), :production_MW => sum => :nonRES_nonThermal_production_uc_MWh),
            on = group_by
        )
        for resource in unique(s_uc.generation.resource)
            out = outerjoin(
                out,
                combine(groupby(s_uc.generation[s_uc.generation.resource .== resource,:], group_by), :production_MW => sum => Symbol(lowercase(resource)*"_production_uc_MWh")),
                on = group_by
            )

        end 
        if :storage in keys(s_uc)
             keys_to_combine = Dict(
                :charge_MW => :storage_charge_uc_MWh,
                :discharge_MW => :storage_discharge_uc_MWh,
             )
            leftjoin!(out, combine(groupby(s_uc.storage, group_by), keys(keys_to_combine) .=> (x -> sum(skipmissing(x))) .=> values(keys_to_combine)), on = group_by)
            out.storage_net_charge_uc_MWh = out.storage_charge_uc_MWh .- out.storage_discharge_uc_MWh
        end
        source_df = nothing
        if :reserve in keys(s_uc)
            keys_to_combine = Dict(
                :reserve_up_MW => :reserve_up_uc_MWh,
                :reserve_down_MW => :reserve_down_uc_MWh,
                :slack_reserve_up_MW => :slack_reserve_up_uc_MWh,
                :slack_reserve_down_MW => :slack_reserve_down_uc_MWh,
                :required_reserve_up_MW => :required_reserve_up_uc_MWh,
                :required_reserve_down_MW => :required_reserve_down_uc_MWh
            )
            source_df = s_uc.reserve
        end 
        if :energy_reserve in keys(s_uc)
            keys_to_combine = Dict(
                :energy_reserve_up_MW => :energy_reserve_up_uc_MWh,
                :energy_reserve_down_MW => :energy_reserve_down_uc_MWh,
                :slack_energy_reserve_up_MW => :slack_energy_reserve_up_uc_MWh,
                :slack_energy_reserve_down_MW => :slack_energy_reserve_down_uc_MWh,
                :required_energy_reserve_up_MW => :required_energy_reserve_up_uc_MWh,
                :required_energy_reserve_down_MW => :required_energy_reserve_down_uc_MWh
            )
            source_df = s_uc.energy_reserve
        end

        if !isnothing(source_df)
            source_df = filter_diagonal_terms(source_df)
            keys_to_combine = Dict(k => v for (k, v) in keys_to_combine if k in propertynames(source_df))
            keys_to_combine_sub = Dict(k => v for (k, v) in keys_to_combine if k in [:reserve_up_MW, :reserve_down_MW, :energy_reserve_up_MW, :energy_reserve_down_MW])
            thermal_filter = coalesce.(source_df.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_thermal,:r_id]), false)
            storage_filter = coalesce.(source_df.r_id .∈ Ref(s_uc.storage_parameters.r_id), false)
            leftjoin!(out, combine(groupby(source_df, group_by), keys(keys_to_combine) .=> (x -> sum(skipmissing(x))) .=> values(keys_to_combine)), on = group_by)
            leftjoin!(out, combine(groupby(source_df[thermal_filter,:], group_by), keys(keys_to_combine_sub) .=> (x -> sum(skipmissing(x))) .=> ("thermal_" .* string.(values(keys_to_combine_sub)))), on = group_by)
            leftjoin!(out, combine(groupby(source_df[storage_filter,:], group_by), keys(keys_to_combine_sub) .=> (x -> sum(skipmissing(x))) .=> ("storage_" .* string.(values(keys_to_combine_sub)))), on = group_by)
        end
        return out
    end
    
    function calculate_dual_variables(s_ed, s_uc, group_by)
        function max_abs_value(x)
            idx = argmax(abs.(x))
            return x[idx]
        end
        function calculate_uc_dual_variables(s_uc, group_by_uc) #TODO: move it to calculate_adecuacy_gcd_KPI()
            keys_to_combine = Dict(
                :dual_supply_demand_balance_MU_MW => :avg_marginal_energy_price_uc_MU_MWh,
                :dual_reserve_up_requirement_MU_MW => :avg_marginal_reserve_up_price_uc_MU_MWh,
                :dual_reserve_down_requirement_MU_MW => :avg_marginal_reserve_down_price_uc_MU_MWh,
                :dual_energy_reserve_up_requirement_MU_MW => :avg_marginal_energy_reserve_up_price_uc_MU_MWh,
                :dual_energy_reserve_down_requirement_MU_MW => :avg_marginal_energy_reserve_down_price_uc_MU_MWh,
            )
            keys_to_combine = Dict(k => v for (k, v) in keys_to_combine if k in propertynames(s_uc.dual_variables))

            group_by_uc_hour = [group_by_uc; :hour]
            # Following combine is used to calculate the maximum absolute value (max_abs_value) of values across :hour_i. If :hour_i is not present, it returns exactly the same dataframe. For :dual_supply_demand_balance_MU_MW, since this value is the same for all :hour_i it has no effect on the returned value.
            aux = combine(groupby(s_uc.dual_variables, group_by_uc_hour), Not(group_by_uc_hour) .=> max_abs_value, renamecols = false)
            return combine(groupby(aux, group_by_uc), keys(keys_to_combine) .=> mean .=> values(keys_to_combine))
        end
        
        out = combine(groupby(s_ed.dual_variables, group_by), :dual_supply_demand_balance_MU_MW => mean => :avg_marginal_energy_price_MU_MWh)
        if !isnothing(s_uc)
            group_by_uc = intersect([:configuration, :day], group_by)
            out =  leftjoin!(out, calculate_uc_dual_variables(s_uc, group_by_uc), on = group_by_uc) #TODO: check if innerjoin can be used instead of left to generate missing values instead of repetead ones
        end
        return out
    end

    function calculate_reserve_activation(s_ed, s_uc, group_by, group_by_uc)
        #TODO: document with equations
       
        # Thermal reserve activation
        thermal_filter_uc = s_uc.generation.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_thermal,:r_id])
        thermal_filter_uc = thermal_filter_uc .&& (s_uc.generation.resource .!= g_NET_GENERATION_FULL_ID)
        thermal_filter_ed = s_ed.generation.r_id .∈ Ref(s_ed.generation_parameters[s_ed.generation_parameters.is_thermal,:r_id])
        thermal_filter_ed = thermal_filter_ed .&& (s_ed.generation.resource .!= g_NET_GENERATION_FULL_ID)
        generation = leftjoin(
            combine(groupby(s_ed.generation[thermal_filter_ed,:], union(group_by, [:hour])), :production_MW => sum => :production_MW), # hourly time profiles
            combine(groupby(s_uc.generation[thermal_filter_uc,:], union(group_by_uc, [:hour])), :production_MW => sum => :production_uc_MW),  # hourly time profiles
            on = union(group_by_uc,[:hour])
            )
        generation.thermal_reserve_activation_MW = generation.production_MW .- generation.production_uc_MW
        generation.thermal_reserve_up_activation_MW = max.(generation.thermal_reserve_activation_MW, 0.0)
        generation.thermal_reserve_down_activation_MW = max.(-generation.thermal_reserve_activation_MW, 0.0)

        #Storage reserve activation
        s_ed.storage.net_discharge_MW .= s_ed.storage.discharge_MW .- s_ed.storage.charge_MW
        s_uc.storage.net_discharge_MW .= s_uc.storage.discharge_MW .- s_uc.storage.charge_MW
        net_discharge = leftjoin(
            combine(groupby(s_ed.storage, union(group_by, [:hour])), :net_discharge_MW => (x -> sum(skipmissing(x))) => :net_discharge_MW), # hourly time profiles
            combine(groupby(s_uc.storage, union(group_by_uc, [:hour])), :net_discharge_MW => (x -> sum(skipmissing(x))) => :net_discharge_uc_MW), # hourly time profiles
            on = union(group_by_uc,[:hour])
        )
        net_discharge.storage_reserve_activation_MW = net_discharge.net_discharge_MW .- net_discharge.net_discharge_uc_MW
        net_discharge.storage_reserve_up_activation_MW = max.(net_discharge.storage_reserve_activation_MW, 0.0)
        net_discharge.storage_reserve_down_activation_MW = max.(-net_discharge.storage_reserve_activation_MW, 0.0)
        return leftjoin(
            combine(groupby(generation, group_by), [:thermal_reserve_up_activation_MW, :thermal_reserve_down_activation_MW] .=> sum .=> [:thermal_reserve_up_activation_MWh, :thermal_reserve_down_activation_MWh] ), # reduce :hour dimension
            combine(groupby(net_discharge, group_by), [:storage_reserve_up_activation_MW, :storage_reserve_down_activation_MW] .=> sum .=> [:storage_reserve_up_activation_MWh, :storage_reserve_down_activation_MWh]), # reduce :hour dimension
            on = group_by
        )
        
    end

    group_by = intersect([:configuration, :day, :iteration, :scenario], propertynames(s_ed.demand))
    gcdi_KPI = calculate_basic_KPI(s_ed, group_by)
    leftjoin!(gcdi_KPI, calculate_objective_function_gcdi_KPI(s_ed, s_uc, group_by), on = group_by)
    
    if :dual_variables in keys(s_ed) && !isempty(s_ed[:dual_variables])
        leftjoin!(gcdi_KPI, calculate_dual_variables(s_ed, s_uc, group_by), on = group_by)
    end

    if !isnothing(s_uc)
        group_by_uc = intersect([:configuration, :day], group_by)
        leftjoin!(gcdi_KPI, calculate_uc_KPI(s_uc, group_by_uc), on = group_by_uc)
        leftjoin!(gcdi_KPI, calculate_reserve_activation(s_ed, s_uc, group_by, group_by_uc), on = group_by)
    end
    if :configuration in propertynames(out)
        out = sort(transform(out, :configuration .=> ByRow(x -> parse_configuration_to_mu(string(x))) .=> :mu), :mu)
    end
    return gcdi_KPI
end

function calculate_adecuacy_gcd_KPI(gcdi_KPI)
    # Metrics from scenarios are aggregated through the mean
    group_by = intersect([:configuration, :day], propertynames(gcdi_KPI))
    keys_to_ignore = union(group_by, [:mu, :iteration])
    keys_to_combine = Dict(
        :objective_value => :EOV,
        :objective_value_uc => :OV_uc, 
    )
    for key in propertynames(gcdi_KPI)
        if !(key in keys(keys_to_combine)) && !(key in keys_to_ignore)
            if occursin("_uc", String(key))
                keys_to_combine[key] = key
            else
                keys_to_combine[key] = Symbol("E_", String(key))
            end
        end
    end
    keys_to_combine = Dict(k => v for (k, v) in keys_to_combine if k in propertynames(gcdi_KPI))
    gcd_KPI = combine(groupby(gcdi_KPI, group_by), keys(keys_to_combine) .=> mean .=> values(keys_to_combine))
    if :configuration in propertynames(gcd_KPI)
        gcd_KPI = sort(transform(gcd_KPI, :configuration .=> ByRow(x -> parse_configuration_to_mu(string(x))) .=> :mu), :mu)
    end
    cols = names(gcd_KPI)
    first_cols = String[]
    if "configuration" in cols
        push!(first_cols, "configuration")
    end
    if "day" in cols
        push!(first_cols, "day")
    end
    if "mu" in cols
        push!(first_cols, "mu")
    end
    uc_cols = sort(filter(col -> occursin("_uc_", col), cols))
    rest_cols = setdiff(cols, vcat(first_cols, uc_cols))
    ordered_cols = vcat(first_cols, uc_cols, rest_cols)
    gcd_KPI = gcd_KPI[:, ordered_cols]
    return gcd_KPI
end

function calculate_objective_function_gcdi_KPI(s_ed, s_uc, group_by)
    keys_objective_value_ = [:production_cost, :fixed_cost, :start_cost, :LOL_cost, :LGEN_cost, :reserve_cost, :slack_reserve_up_cost, :slack_reserve_down_cost,:energy_reserve_cost, :slack_energy_reserve_up_cost, :slack_energy_reserve_down_cost, :slack_SOE_final_cost]
    keys_objective_value = intersect(keys_objective_value_, propertynames(s_ed.objective_function))
    out = combine(groupby(s_ed.objective_function, group_by), keys_objective_value .=> (x -> sum(skipmissing(x))), renamecols = false)
    out.OPEX = out.production_cost .+ out.fixed_cost .+ out.start_cost # this OPEX definition corresponds to model[:OPEX]
    out.objective_value = sum(eachcol(out[:,keys_objective_value]))
    # out.objective_value = select(out, keys_objective_value .=> ByRow(sum) => :objective_value)[:objective_value]
    # out.objective_value = out.OPEX .+ out.LOL_cost .+ out.LGEN_cost .+ out.reserve_cost # this objective value definition correspond to objective_function(model)
    if !isnothing(s_uc)
        source_df = s_uc.objective_function
        group_by_uc = intersect([:configuration, :day], group_by)
        keys_objective_value_uc = intersect(keys_objective_value_, propertynames(s_uc.objective_function)) 
        leftjoin!(out, combine(groupby(s_uc.objective_function, group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.(keys_objective_value_uc, "_uc")), on = group_by_uc)
        
        
        # Adding costs differentiated by asset type
        var_filter = coalesce.(s_uc.objective_function.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_var,:r_id]), false) #  coalesce is needed becase "system" has no id
        thermal_filter = coalesce.(s_uc.objective_function.r_id .∈ Ref(s_uc.generation_parameters[s_uc.generation_parameters.is_thermal,:r_id]), false)
        storage_filter = coalesce.(s_uc.objective_function.r_id .∈ Ref(s_uc.storage_parameters.r_id), false)
        nt_nonvar_filter = .!var_filter .& .!thermal_filter .& .!storage_filter  .&& coalesce.(s_uc.objective_function.resource .!= g_SYSTEM_ID, false) # to avoid including LOL and LGEN costs which are not associated to a specific r_id
        leftjoin!(out, combine(groupby(s_uc.objective_function[thermal_filter,:], group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.("thermal_",keys_objective_value_uc, "_uc")), on = group_by_uc)
        leftjoin!(out, combine(groupby(s_uc.objective_function[var_filter,:], group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.("var_",keys_objective_value_uc, "_uc")), on = group_by_uc)
        leftjoin!(out, combine(groupby(s_uc.objective_function[nt_nonvar_filter,:], group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.("nt_nonvar_",keys_objective_value_uc, "_uc")), on = group_by_uc)
        leftjoin!(out, combine(groupby(s_uc.objective_function[storage_filter,:], group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.("storage_",keys_objective_value_uc, "_uc")), on = group_by_uc)
       
        out.OPEX_uc = out.production_cost_uc .+ out.fixed_cost_uc .+ out.start_cost_uc
        out.objective_value_uc = out.OPEX_uc
        if hasproperty(out, :reserve_cost_uc)
            out.objective_value_uc .+= out.reserve_cost_uc
        end 
        if hasproperty(out, :energy_reserve_cost_uc)
            out.objective_value_uc .+= out.energy_reserve_cost_uc 
        end
        if hasproperty(out, :slack_reserve_up_cost_uc) && hasproperty(out, :slack_reserve_down_cost_uc)
            out.objective_value_uc .+= (out.slack_reserve_up_cost_uc .+ out.slack_reserve_down_cost_uc)
        end
        if hasproperty(out, :slack_energy_reserve_up_cost_uc) && hasproperty(out, :slack_energy_reserve_down_cost_uc)
            out.objective_value_uc .+= (out.slack_energy_reserve_up_cost_uc .+ out.slack_energy_reserve_down_cost_uc)
        end
        if hasproperty(out, :LOL_cost_uc)
            out.objective_value_uc .+= out.LOL_cost_uc
        end
        if hasproperty(out, :LGEN_cost_uc)
            out.objective_value_uc .+= out.LGEN_cost_uc
        end
        out.redispatch_cost = out.OPEX .- out.OPEX_uc
    end
    if :configuration in propertynames(out)
        out = sort(transform(out, :configuration .=> ByRow(x -> parse_configuration_to_mu(string(x))) .=> :mu), :mu)
    end

    return out
end
