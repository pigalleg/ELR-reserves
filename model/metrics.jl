using DataFrames
using Statistics
using Parquet2

parse_configuration_to_mu(x) = !isnothing(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))) ? parse(Float64, replace(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))[1], "_" => ".")) : 1

function calculate_adecuacy_gcdi_KPI(s_ed, s_uc = nothing)
    # if stochastic, s_ed = s_suc and s_uc = nothing
    function calculate_basic_KPI(s_ed, group_by, thres = .001)
        f_LOL(x, y) = (
            LLD_h = count(>(thres), x),
            ENS_MWh = sum(x),
            input_load_MWh = sum(y) + sum(x) # input_load = production + LOL
        )
        f_CUR(x, y) = (
            CURD_h = count(>(thres), x),
            CUR_MWh = sum(x),
            input_RES_production_MWh = sum(y) + sum(x) # input_RES_production = RES_production + CUR
        )

        RES_filter = in(["onshore_wind_turbine", "small_hydroelectric", "solar_photovoltaic", "net_generation"]).(s_ed.generation.resource)
        @infiltrate
        out = outerjoin(
            combine(groupby(s_ed.demand, group_by), [:LOL_MW, :demand_MW] => ((x, y) -> f_LOL(x, y)) => AsTable),
            combine(groupby(s_ed.generation[RES_filter, :], group_by), [:curtailment_MW, :production_MW] => ((x, y) -> f_CUR(x, y)) => AsTable),
            combine(groupby(s_ed.generation[.!RES_filter, :], group_by), :production_MW => sum => :nonRES_production_MWh),
            on = group_by
        )
        if :LGEN_MW in propertynames(s_ed.demand)
            out = outerjoin(out, combine(groupby(s_ed.demand, group_by), :LGEN_MW => sum => :LGEN_MWh), on = group_by)
        end
        return out
    end

    function calculate_dual_variables(s_ed, s_uc, group_by) #TODO: if isnothing(s_uc)
        function max_abs_value(x)
            idx = argmax(abs.(x))
            return x[idx]
        end
        function calculate_uc_dual_variables(s_uc, group_by_uc)
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
            out =  leftjoin!(out, calculate_uc_dual_variables(s_uc, group_by_uc), on = group_by_uc)
        end
        return out
    end

    group_by = intersect([:configuration, :day, :iteration, :scenario], propertynames(s_ed.demand))
    gcdi_KPI = calculate_basic_KPI(s_ed, group_by)
    leftjoin!(gcdi_KPI, calculate_objective_function_gcdi_KPI(s_ed, s_uc, group_by), on = group_by)
    if :dual_variables in keys(s_ed) && !isempty(s_ed[:dual_variables])
        leftjoin!(gcdi_KPI, calculate_dual_variables(s_ed, s_uc, group_by), on = group_by)
    end
    if :configuration in propertynames(out)
        out = sort(transform(out, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu), :mu)
    end
    return gcdi_KPI
end

function calculate_adecuacy_gcd_KPI(gcdi_KPI)
    group_by = intersect([:configuration, :day], propertynames(gcdi_KPI))
    keys_to_combine = Dict(
        :LLD_h => :LOLE, :ENS_MWh => :EENS, :CURD_h => :CURE, :CUR_MWh => :ECUR, :LGEN_MWh => :ELGEN,
        :input_load_MWh => :input_load_MWh, :input_RES_production_MWh => :input_RES_production_MWh, :nonRES_production_MWh => :nonRES_production_MWh,
        :objective_value => :EOV, :objective_value_uc => :OV_uc, :OPEX => :EOPEX, :OPEX_uc => :OPEX_uc, :redispatch_cost => :E_redispatch_cost, :LOL_cost => :EENS_cost, :LGEN_cost => :ELGEN_cost, :reserve_cost => :reserve_cost, :reserve_cost_uc => :reserve_cost_uc,
        :avg_marginal_energy_price_MU_MWh => :E_avg_marginal_energy_price_MU_MWh, :avg_marginal_energy_price_uc_MU_MWh => :avg_marginal_energy_price_uc_MU_MWh,
        :avg_marginal_reserve_up_price_uc_MU_MWh => :avg_marginal_reserve_up_price_uc_MU_MWh, :avg_marginal_reserve_down_price_uc_MU_MWh => :avg_marginal_reserve_down_price_uc_MU_MWh,
        :avg_marginal_energy_reserve_up_price_uc_MU_MWh => :avg_marginal_energy_reserve_up_price_uc_MU_MWh, :avg_marginal_energy_reserve_down_price_uc_MU_MWh => :avg_marginal_energy_reserve_down_price_uc_MU_MWh
    )
    keys_to_combine = Dict(k => v for (k, v) in keys_to_combine if k in propertynames(gcdi_KPI))

    gcd_KPI = combine(groupby(gcdi_KPI, group_by), keys(keys_to_combine) .=> mean .=> values(keys_to_combine))
    if :configuration in propertynames(gcd_KPI)
        gcd_KPI = sort(transform(gcd_KPI, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu), :mu)
    end
    return gcd_KPI
end

function calculate_objective_function_gcdi_KPI(s_ed, s_uc, group_by)
    keys_objective_value = intersect([:production_cost, :fixed_cost, :start_cost, :LOL_cost, :LGEN_cost, :reserve_cost], propertynames(s_ed.objective_function))
    out = combine(groupby(s_ed.objective_function, group_by), keys_objective_value .=> (x -> sum(skipmissing(x))), renamecols = false)
    out.OPEX = out.production_cost .+ out.fixed_cost .+ out.start_cost # this OPEX definition correspond to model[:OPEX]
    out.objective_value = sum(eachcol(out[:,keys_objective_value]))
    # out.objective_value = select(out, keys_objective_value .=> ByRow(sum) => :objective_value)[:objective_value]
    # out.objective_value = out.OPEX .+ out.LOL_cost .+ out.LGEN_cost .+ out.reserve_cost # this objective value definition correspond to objective_function(model)

    if !isnothing(s_uc)
        group_by_uc = intersect([:configuration, :day], group_by)
        keys_objective_value_uc = intersect(keys_objective_value, propertynames(s_uc.objective_function))
        leftjoin!(out, combine(groupby(s_uc.objective_function, group_by_uc), keys_objective_value_uc .=> (x -> sum(skipmissing(x))) .=> Symbol.(keys_objective_value_uc, "_uc")), on = group_by_uc)
        out.OPEX_uc = out.production_cost_uc .+ out.fixed_cost_uc .+ out.start_cost_uc
        out.objective_value_uc = out.OPEX_uc .+ out.reserve_cost_uc
        out.redispatch_cost = out.OPEX .- out.OPEX_uc
    end
    if :configuration in propertynames(out)
        out = sort(transform(out, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu), :mu)
    end

    return out
end
