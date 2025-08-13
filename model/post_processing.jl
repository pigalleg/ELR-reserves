using DataFrames
using Parquet2
include("./pre_processing.jl")
include("./unit_commitment/config.jl")

FIELD_FOR_ENRICHING = [:r_id, :resource, :full_id]
SOLUTION_KEYS = [:demand, :generation, :storage, :reserve, :energy_reserve, :scalar, :generation_parameters, :storage_parameters, :objective_function, :dual_variables]

function value_to_df(var, stochastic)
    if stochastic
        x,y = (axes(var)[1:ndims(var)-1], last(axes(var))) 
        return vcat([insertcols(value_to_df_(var[x...,s]), :scenario => s) for s in y]...)
    else
        return value_to_df_(var)
    end
end

function value_to_df_(var)
    if var isa JuMP.Containers.DenseAxisArray
        if ndims(var) == 1
            return value_to_df_1dim(var)
        elseif ndims(var) == 2
            value_to_df_2dim(var)
        else
            println("Could not identify type of output. Returning initial variable...")
            return var
        end
    elseif var isa JuMP.Containers.SparseAxisArray
        if ndims(var) == 2
            return value_to_df_multidim(var, [:hour_i, :hour]) # this configuration is used for dual of energy reserve requirement
        else
            return value_to_df_multidim(var, [:r_id, :hour_i, :hour])
        end
    else
        println("Could not identify type of output. Returning initial variable...")
        return var
    end
end

function value_to_df_multidim(var, new_index_list = nothing)
    size_of_indices = length(first(keys(value.(var).data)))
    indices = [Symbol("index_"*string(i)) for i in 1:size_of_indices]
    out = DataFrame(index = collect(keys(value.(var).data)), value = collect(values(value.(var).data)))
    transform!(out, :index .=> [ByRow(x -> x[i]) .=> indices[i] for i in 1:size_of_indices])
    select!(out, Not(:index))
    if !isnothing(new_index_list)
        for i in 1:length(new_index_list)
            rename!(out, indices[i] => new_index_list[i])
        end
    end
    return out
end

function value_to_df_1dim(var)
    return DataFrame(hour = value.(var).axes[1], value = value.(var).data)
end

function value_to_df_2dim(var)
    solution = DataFrame(value.(var).data, :auto)
    ax1 = value.(var).axes[1]
    ax2 = value.(var).axes[2]
    cols = names(solution)
    insertcols!(solution, 1, :r_id => ax1)
    solution = stack(solution, Not(:r_id), variable_name=:hour)
    solution.hour = foldl(replace, [cols[i] => ax2[i] for i in 1:length(ax2)], init = solution.hour)
    #   rename!(solution, :value => :gen)
    solution.hour = convert.(Int64,solution.hour)
    return solution
end

function get_fixed_model(model_, copy_model)
    # TODO: this function should be called in solve_economic_dispatch_ and solve_unit_commitment rather than by get_solution
    # the main problem is that get_solution is called in main
    if is_non_feasible(model_)
        println("Model is not feasible. Returning the original model.")
        return model_
    end
    if copy_model
        model = copy_initialize(model_)
        optimize!(model) # needs to be solved after copying. Check: objective_value(model_) == objective_value(model)
    else
        model = model_
    end
    try
        fix_discrete_variables(model) #https://jump.dev/JuMP.jl/stable/api/JuMP/#JuMP.fix_discrete_variables
        # Gurobi.GRBconverttofixed(backend(model_).optimizer.model) # https://docs.gurobi.com/projects/optimizer/en/current/reference/c/solving.html#c.GRBconverttofixed
        optimize!(model) # needs to be re-solved after fixing
    catch e
        @warn "Failed to fix discrete variables: $(e). Returning original model without fixing discrete variables."
    end
    optimize!(model) # We optimize even if catch activates because the model losses optimizations status.
    return model
end

function get_nonfeasbile_model_information(model)
    # Output is a NamedTuple with scalar information about the model. The 'scalar' field is also present on feasible models.
    return (
        scalar = DataFrame(
            termination_status_discrete_model = termination_status(model),# string(termination_status(model)),
            primal_status_discrete_model = primal_status(model), #string(primal_status(model)),
            dual_status_discrete_model = dual_status(model) #string(dual_status(model))
        ),      
    )
end


function merge_solutions(solutions::Dict, merge_keys = [:iteration])
    #TODO can be done more elegantly
    # called only by ED
    solution_keys = union([keys(v) for (k,v) in solutions]...)
    aux = Dict(k => [] for k in solution_keys)
    for d in keys(solutions), k in intersect(keys(solutions[d]), solution_keys)
        aux_ = DataFrame(collect(repeat([isa(d,Tuple) ? d : tuple(d)], size(solutions[d][k],1))), merge_keys)
        push!(aux[k], hcat(solutions[d][k], aux_))
    end
    return NamedTuple(k => vcat(aux[k]..., cols = :union) for k in keys(aux))
end

function get_solution(model, stochastic = false, get_dual_variables = false, copy_model = true)
    # We extract values before fixing the model because if copy_model = false, then the model changes and has no relative gap.
    scalar_df  = DataFrame(
        objective_value_discrete_model = objective_value(model),
        termination_status_discrete_model = termination_status(model),
        primal_status_discrete_model = primal_status(model),
        dual_status_discrete_model = dual_status(model),
        relative_gap_discrete_model = relative_gap(model),
        solve_time = solve_time(model))
    
    if get_dual_variables # when get_dual_variables = true, output contains the fixed model's solution
        model_ = get_fixed_model(model, copy_model) # it can happen the fixing process fails. The model then returns the initial model. No dual variables will be extracted in the solution.
    else
        model_ =  model
    end

    scalar_df.objective_value .= objective_value(model_)
    scalar_df.termination_status .= termination_status(model_)
    scalar_df.primal_status .= primal_status(model_)
    scalar_df.dual_status .= dual_status(model_)
    scalar_df.OPEX .=  value(model_[:OPEX])
    return merge(
        get_solution_variables(model_, stochastic),
        get_solution_dual_variables(model_, stochastic),
        (scalar = scalar_df,),
    )   
end

function get_solution_variables(model, stochastic)
    variables_to_get = [:GEN, :COMMIT, :SHUT, :START, :CH, :DIS, :SOE, :SOEUP, :SOEDN, :ESOEUP, :ESOEDN, :RESUP, :CHRESDNCH, :CHRESUPCH, :DISRESUPDIS, :DISRESDNDIS, :RESDN, :ERESUP, :ERESDN, :LOL, :LGEN, :SOEUP_EC, :SOEDN_EC, :RESUPDIS, :RESUPCH, :RESDNDIS, :RESDNCH, :SRESUP, :SRESDN, :SERESUP, :SERESDN, :RRESUP, :RRESDN, :RERESUP, :RERESDN, :SSOEFinal]   
    return NamedTuple(k => value_to_df(model[k], stochastic) for k in intersect(keys(object_dictionary(model)), variables_to_get))
end

function get_solution_dual_variables(model, stochastic) # output's keys are of the format "$(constraint_name_)_dual"
    constraints_to_get = [:SupplyDemandBalance, :ResUpRequirement, :ResDnRequirement, :EnergyResUpRequirement, :EnergyResDnRequirement, :SOEUPMax, :SOEDNMax, :SOEUPMin, :SOEDNMin, :ESOEUPMax, :ESOEDNMax, :ESOEUPMin, :ESOEDNMin, :RampUp_thermal, :RampDn_thermal, :RampUp_nonthermal, :RampDn_nonthermal] #TODO: :SOEFinalUp, :SOEFinalDn
    if has_duals(model)
        return NamedTuple(Symbol("$(string(k))_dual") => value_to_df(dual.(model[k]), stochastic) for k in intersect(keys(object_dictionary(model)), constraints_to_get))
    else
        return NamedTuple()
    end
end

function get_model_solution(model, gen_df, gen_variable; copy_model = true, loads = nothing, scenarios = nothing, config...)
    #TODO: loads not used 
    # Model is either UC or ED or SUC
    get_dual_variables = get(config, :get_dual_variables, g_dual_variables)
    storage = get(config, :storage, g_storage)
    enriched_solution = get(config, :enriched_solution, g_enriched_solution)
    stochastic = !isnothing(scenarios)
    # sets = get_sets(gen_df)
    parameters_for_enriching = (MIPGap = parameter_value(model[:MIPGap]),)
    if haskey(model, :VRESERVE) # UC
        parameters_for_enriching = merge(parameters_for_enriching, (VRESERVE = parameter_value(model[:VRESERVE]),))
    end
    if haskey(model, :VLOL) && haskey(model, :VLGEN) # ED or SUC
        parameters_for_enriching = merge(parameters_for_enriching,
            (VLOL = Array(parameter_value.(model[:VLOL])),
            VLGEN = Array(parameter_value.(model[:VLGEN])))
        )
    end
    if haskey(model, :μ_up) && haskey(model, :μ_dn) # UC or SUC
        parameters_for_enriching = merge(parameters_for_enriching,
            (μ_up = Array(parameter_value.(model[:μ_up])),
            μ_dn = Array(parameter_value.(model[:μ_dn])))
        )
    end
    if haskey(model, :VSRESUP) && haskey(model, :VSRESDN) # UC
        parameters_for_enriching = merge(parameters_for_enriching,
            (VSRESUP = Array(parameter_value.(model[:VSRESUP])),
            VSRESDN = Array(parameter_value.(model[:VSRESDN])))
        )
    end
    if haskey(model, :FeasibilityTol)
        parameters_for_enriching = merge(parameters_for_enriching, (FeasibilityTol = parameter_value(model[:FeasibilityTol]),))
    end
    if haskey(model, :VSSOEFinal)
        parameters_for_enriching = merge(parameters_for_enriching, (VSSOEFinal = parameter_value(model[:VSSOEFinal]),))
    end
    if enriched_solution
        get_objective_function = true
        if stochastic
            loads_ = stack(scenarios.demand, Not([:day,:hour]), variable_name = :scenario, value_name = :demand)
        else
            loads_ = loads  
        end
        return enrich_dfs(get_solution(model, stochastic, get_dual_variables, copy_model), gen_df, loads_, gen_variable, storage, parameters_for_enriching, get_objective_function) 
    else
        return get_solution(model, stochastic, get_dual_variables)
    end
end

function enrich_dfs(solution, gen_df, loads, gen_variable, storage, parameters, objective_function = true)
    #TODO: deal with missing values
    #TODO: include objective_function for stochastic solution
    out = Dict(pairs(solution[[:scalar]]))
    out[:generation] = get_enriched_generation(solution, gen_df, gen_variable)
    out[:generation_parameters] = get_generation_parameters(gen_df)
    
    data = copy(gen_df[!,FIELD_FOR_ENRICHING]) # data for enriching
    if !isnothing(storage)  # storage elements are stored
        append!(data, storage[!,FIELD_FOR_ENRICHING] )
        out[:storage] = get_enriched_storage(solution, data)
        out[:storage_parameters] = get_storage_parameters(storage)
    end
    # energy_reserve solutions have :RESUP and :RESDN so we need to extra check
    if haskey(solution, :RESUP) && haskey(solution, :RESDN) && (!haskey(solution, :ERESUP) || !haskey(solution, :ERESDN)) # UC+ED
        out[:reserve] =  get_enriched_reserve(solution, data, parameters.FeasibilityTol)
    end
    if haskey(solution, :ERESUP) && haskey(solution, :ERESDN)
        out[:energy_reserve] =  get_enriched_energy_reserve(solution, data, parameters.FeasibilityTol)
    end
    if haskey(solution, :SupplyDemandBalance_dual)
        out[:dual_variables] =  get_enriched_duals(solution)
    end
    out[:demand] = get_enriched_demand(solution, loads)
    if objective_function
        out[:objective_function] = get_enriched_objective_value(out, gen_df, storage, parameters)
    end
    # out[:constraints] = get_constraints(solution)
    return NamedTuple(out)
end



function get_enriched_duals(solution)
    
    aux = rename(solution.SupplyDemandBalance_dual, :value => :dual_supply_demand_balance_MU_MW) # UC + SUC
    aux.r_id .= missing
    if haskey(solution, :ResUpRequirement_dual) # UC we assume that ResDnRequirement_dual is present
        aux = outerjoin( # left join also works
            aux,
            innerjoin(
                rename(solution.ResUpRequirement_dual, :value => :dual_reserve_up_requirement_MU_MW),
                rename(solution.ResDnRequirement_dual, :value => :dual_reserve_down_requirement_MU_MW),
                on = [:hour]),
            on = :hour)
    
    elseif haskey(solution, :EnergyResUpRequirement_dual) && haskey(solution, :EnergyResDnRequirement_dual) # UC. 
        aux.hour_i = aux.hour
        aux = outerjoin(
            aux,
            innerjoin(
                rename(solution.EnergyResUpRequirement_dual, :value => :dual_energy_reserve_up_requirement_MU_MW),
                rename(solution.EnergyResDnRequirement_dual, :value => :dual_energy_reserve_down_requirement_MU_MW),
                on = [:hour, :hour_i]),
            on = [:hour, :hour_i])
    end

    if haskey(solution, :SOEUPMax_dual) && haskey(solution, :SOEDNMax_dual) && haskey(solution, :SOEUPMin_dual) && haskey(solution, :SOEDNMin_dual) #UC
        aux = outerjoin(
            aux,
            innerjoin(
                rename(solution.SOEUPMax_dual, :value => :dual_SOE_up_max_MU_MW),
                rename(solution.SOEDNMax_dual, :value => :dual_SOE_down_max_MU_MW),
                rename(solution.SOEUPMin_dual, :value => :dual_SOE_up_min_MU_MW),
                rename(solution.SOEDNMin_dual, :value => :dual_SOE_down_min_MU_MW),
                on = [:r_id, :hour]),
            on = [:r_id, :hour],
            matchmissing = :equal
        )
    elseif haskey(solution, :ESOEUPMax_dual) && haskey(solution, :ESOEDNMax_dual) && haskey(solution, :ESOEUPMin_dual) && haskey(solution, :ESOEDNMin_dual) # UC
        aux = outerjoin(
            aux,
            innerjoin(
                rename(solution.ESOEUPMax_dual, :value => :dual_ESOE_up_max_MU_MW),
                rename(solution.ESOEDNMax_dual, :value => :dual_ESOE_down_max_MU_MW),
                rename(solution.ESOEUPMin_dual, :value => :dual_ESOE_up_min_MU_MW),
                rename(solution.ESOEDNMin_dual, :value => :dual_ESOE_down_min_MU_MW),
                on = [:r_id, :hour, :hour_i]),
            on = [:r_id, :hour,:hour_i],
            matchmissing = :equal
        )
    end

    join_on = intersect([:r_id, :hour, :scenario], propertynames(aux))
    if haskey(solution, :RampUp_thermal_dual) && haskey(solution, :RampDn_thermal_dual) # UC + ED + SUC
        aux = outerjoin(
            aux,
            innerjoin(
                rename(solution.RampUp_thermal_dual, :value => :dual_ramp_up_thermal_MU_MW),
                rename(solution.RampDn_thermal_dual, :value => :dual_ramp_down_thermal_MU_MW),
                on = join_on),
            on = join_on,
            matchmissing = :equal
        )

    end
    if haskey(solution, :RampUp_nonthermal_dual) && haskey(solution, :RampDn_nonthermal_dual) #  # UC + ED + SUC.
        aux = outerjoin(
            aux,
            innerjoin(
                rename(solution.RampUp_nonthermal_dual, :value => :dual_ramp_up_nonthermal_MU_MW),
                rename(solution.RampDn_nonthermal_dual, :value => :dual_ramp_down_nonthermal_MU_MW),
                on = join_on),
            on = join_on,
            matchmissing = :equal
        )   
    end
    # if haskey(solution, :SOEFinalUp_dual) # ED. We assume that SOEFinalDn_dual is present
    #     join_on = intersect([:r_id, :hour], propertynames(aux))
    #     aux = leftjoin(
    #         aux,
    #         innerjoin(
    #             rename(solution.SOEFinalUp_dual, :value => :dual_SOE_end_up_MU_MW),
    #             rename(solution.SOEFinalDn_dual, :value => :dual_SOE_end_down_MU_MW),
    #             on = [:r_id, :hour]),
    #         on = join_on  ,
    #         matchmissing = :equal 
    #     )
    # end
    if :hour_i in propertynames(aux) # this is the case of energy reserve duals
        select!(aux, vcat([:hour, :hour_i], setdiff(Symbol.(names(aux)), [:hour, :hour_i]))) # reordering with :hour and :hour_i first
    end
    return aux
end
    

function get_enriched_energy_reserve(solution, data, atol)
    rr_up_ratio = 1
    rr_dn_ratio = 1
    aux = leftjoin(
        innerjoin(
            rename(solution.ERESUP, :value => :energy_reserve_up_MW),
            rename(solution.ERESDN, :value => :energy_reserve_down_MW),
            on = [:r_id, :hour, :hour_i],
        ),
        data[!,FIELD_FOR_ENRICHING],
        on = :r_id
    )
    if haskey(solution, :SERESUP) && haskey(solution, :SERESDN)
        aux_ = innerjoin(
            rename(solution.SERESUP, :value => :slack_energy_reserve_up_MW),
            rename(solution.SERESDN, :value => :slack_energy_reserve_down_MW),
            on = [:hour_i, :hour]
        )
        aux_.resource .= "system"
        aux = outerjoin(
            aux, 
            aux_,
            on = [:resource, :hour_i, :hour])
    end
    if haskey(solution, :RERESUP) && haskey(solution, :RERESDN)
        aux_ = innerjoin(
            rename(solution.RERESUP, :value => :required_energy_reserve_up_MW),
            rename(solution.RERESDN, :value => :required_energy_reserve_down_MW),
            on = [:hour_i, :hour]
        )
        aux_.resource .= "system"
        aux = outerjoin(
            aux, 
            aux_,
            on = [:resource, :hour_i, :hour])

        r_up = sum(skipmissing(aux.energy_reserve_up_MW))
        r_dn = sum(skipmissing(aux.energy_reserve_down_MW))
        rr_up = sum(skipmissing(aux.required_energy_reserve_up_MW))
        rr_dn = sum(skipmissing(aux.required_energy_reserve_down_MW))
        if !isapprox(r_up, rr_up, atol = atol) && r_up > rr_up
            @warn "Reserve to required reserve up ratio is greater than 1 (with tolerance): $(r_up/rr_up)"
        end
        if !isapprox(r_dn, rr_dn, atol = atol) && r_dn > rr_dn
            @warn "Reserve to required reserve dn ratio is greater than 1 (with tolerance): $(r_dn/rr_dn)"
        end
    end
    return aux
end

function get_enriched_reserve(solution, data, atol)
    rr_up_ratio = 1
    rr_dn_ratio = 1
    aux = leftjoin(
        innerjoin(
            rename(solution.RESUP, :value => :reserve_up_MW),
            rename(solution.RESDN, :value => :reserve_down_MW),
            on = [:r_id, :hour]),
        data[!,FIELD_FOR_ENRICHING],
        on = :r_id
    )
    if haskey(solution, :RESUPDIS)
        aux = outerjoin(
            aux,
            rename(solution.RESUPDIS, :value => :reserve_discharge_up_MW),
            rename(solution.RESUPCH, :value => :reserve_charge_up_MW),
            rename(solution.RESDNDIS, :value => :reserve_discharge_down_MW),
            rename(solution.RESDNCH, :value => :reserve_charge_down_MW),
            on = [:r_id, :hour]
        )
    end
    if haskey(solution, :CHRESDNCH)
        aux = outerjoin(
            aux,
            rename(solution.CHRESDNCH, :value => :chargue_reserve_max_MW),
            rename(solution.CHRESUPCH, :value => :chargue_reserve_min_MW),
            rename(solution.DISRESUPDIS, :value => :discharge_reserve_max_MW),
            rename(solution.DISRESDNDIS, :value => :discharge_reserve_min_MW),
            on = [:r_id, :hour]
        )
    end
    if haskey(solution, :SRESUP) && haskey(solution, :SRESDN)
        aux_ = innerjoin(
            rename(solution.SRESUP, :value => :slack_reserve_up_MW),
            rename(solution.SRESDN, :value => :slack_reserve_down_MW),
            on = [:hour]
        )
        aux_.resource .= "system"
        aux = outerjoin(
            aux, 
            aux_,
            on = [:resource, :hour,])
    end
    if haskey(solution, :RRESUP) && haskey(solution, :RRESDN)
        aux_ = innerjoin(
            rename(solution.RRESUP, :value => :required_reserve_up_MW),
            rename(solution.RRESDN, :value => :required_reserve_down_MW),
            on = [:hour]
        )
        aux_.resource .= "system"
        aux = outerjoin(
            aux, 
            aux_,
            on = [:resource, :hour,])
        r_up = sum(skipmissing(aux.reserve_up_MW))
        r_dn = sum(skipmissing(aux.reserve_down_MW))
        rr_up = sum(skipmissing(aux.required_reserve_up_MW))
        rr_dn = sum(skipmissing(aux.required_reserve_down_MW))
        if !isapprox(r_up, rr_up, atol = atol) && r_up > rr_up
            @warn "Reserve to required reserve up ratio is greater than 1 (with tolerance): $(r_up/rr_up)"
        end
        if !isapprox(r_dn, rr_dn, atol = atol) && r_dn > rr_dn
            @warn "Reserve to required reserve dn ratio is greater than 1 (with tolerance): $(r_dn/rr_dn)"
        end
    end

    return aux
end

function get_enriched_storage(solution, data)
    join_on = intersect([:r_id, :hour, :scenario], propertynames(solution.CH))
    aux = innerjoin(
        rename(solution.CH, :value => :charge_MW),
        rename(solution.DIS, :value => :discharge_MW),
        rename(solution.SOE, :value => :SOE_MWh),
        on = join_on
    )
    if haskey(solution, :SOEUP) & haskey(solution, :SOEDN)
        aux = innerjoin(
            aux,
            rename(solution.SOEUP, :value => :envelope_up_MWh),
            rename(solution.SOEDN, :value => :envelope_down_MWh),
            on = join_on
        )
    end
    if haskey(solution, :ESOEUP) & haskey(solution, :ESOEDN)
        aux.hour_i = aux.hour
        join_on = [:r_id, :hour_i, :hour]
        aux2 = innerjoin(
            rename(solution.ESOEUP, :value => :envelope_up_MWh),
            rename(solution.ESOEDN, :value => :envelope_down_MWh),
            on = join_on
        
        )
        aux = outerjoin(aux, aux2, on = join_on)
    end
    # if haskey(solution, :SOEUP_ED) & haskey(solution, :SOEDN_EC) # deprecated
    #     aux = innerjoin(
    #         aux,
    #         rename(solution.SOEUP_ED, :value => :envelope_up_MWh),
    #         rename(solution.SOEDN_ED, :value => :envelope_down_MWh),
    #         on = [:r_id, :hour]
    #     )
    # end

    if haskey(solution, :SSOEFinal)
       aux = outerjoin(
        aux, 
        rename(solution.SSOEFinal, :value => :slack_SOE_final_MWh),
        on = join_on,
        order = :left
       )
    end 
    return leftjoin(aux, data[!,FIELD_FOR_ENRICHING], on = :r_id)
end

function get_enriched_generation(solution, gen_df, gen_variable)
    join_on = intersect([:r_id, :hour, :scenario], propertynames(solution.GEN), propertynames(gen_variable))
    curtail = leftjoin(solution.GEN, gen_variable, on = join_on)
    curtail.value = curtail.max_production_mw - curtail.value
    # curtail.value = curtail.cf .* curtail.existing_cap_mw - curtail.value
    aux = outerjoin(
        outerjoin(  
            rename(solution.GEN, :value => :production_MW), # production refers to the actual decision variable, i.e., production + curtail = existing_cap_mw*cf
            rename(curtail[!, union(join_on, [:value])], :value => :curtailment_MW),
            rename(solution.COMMIT, :value => :commit),
            rename(solution.START, :value => :start),
            rename(solution.SHUT, :value => :shut),
            on = join_on #[:r_id, :hour]
        ),
        gen_df[!,FIELD_FOR_ENRICHING],
        on = :r_id
    )
    replace!(aux.curtailment_MW, missing => 0)
    return aux
end

function get_enriched_demand(solution, loads)
    join_on = intersect([:hour, :scenario], propertynames(loads))
    demand_ = "day" in names(loads) ? select(loads, Not(:day)) : loads
    demand = rename(demand_, [ x => "demand_MW" for x in names(select(demand_,Not(join_on)))]) # select only the column with demand values and change it to 'demand_MW'
    # demand =  rename(loads, :demand => :demand_MW)
    demand.r_id .= missing
    demand.resource .= "system"
    if haskey(solution, :LOL)
        demand.demand_MW =  demand.demand_MW - solution[:LOL].value
        demand = leftjoin(
            demand, 
            rename(solution[:LOL], :value => :LOL_MW),
            on = join_on
        )
    end
    if haskey(solution, :LGEN)
        LGEN = copy(solution.LGEN)
        join_on = intersect([:hour, :resource, :scenario], propertynames(LGEN))
        # LGEN.r_id .= missing
        LGEN.resource .= "system"
        demand = outerjoin(
            demand,
            rename(LGEN[!,union(join_on, [:value])], :value => :LGEN_MW),
            on = join_on
        )
        replace!(demand.LGEN_MW, missing => 0)
    end
    return demand
end

function get_enriched_objective_value(enriched_solution, gen_df, storage, parameters)
    #TODO: deal with missing values
    function check_cost_consistency()
        aux = combine(groupby(cost, intersect([:scenario], propertynames(cost))), [:production_cost, :fixed_cost, :start_cost] .=> (x -> sum(skipmissing(x))), renamecols = false)
        sum_cost = mean(aux.production_cost.+aux.fixed_cost.+aux.start_cost) # For SUC, this takes the mean across scenarios. For UC and ED, the mean does not have any effect because the DF's number of rows is always 1.
        if !isapprox(enriched_solution[:scalar].OPEX[1], sum_cost; rtol =  parameters.MIPGap) # OPEX = production_cost + fixed_cost + start_cost
            error("Start and operational cost mismatch with OPEX")
        end
        if :reserve_cost in propertynames(cost)
            sum_cost += sum(skipmissing(cost.reserve_cost))
            sum_cost += sum(skipmissing(cost.slack_reserve_up_cost))
            sum_cost += sum(skipmissing(cost.slack_reserve_down_cost))
        end
        if :energy_reserve_cost in propertynames(cost)
            sum_cost += sum(skipmissing(cost.energy_reserve_cost))
            sum_cost += sum(skipmissing(cost.slack_energy_reserve_up_cost))
            sum_cost += sum(skipmissing(cost.slack_energy_reserve_down_cost))
        end
        if :LOL_cost in propertynames(cost)
            aux = combine(groupby(cost, intersect([:scenario], propertynames(cost))),[:LOL_cost, :LGEN_cost] .=> (x->sum(skipmissing(x))), renamecols = false)
            sum_cost += mean(aux.LOL_cost .+ aux.LGEN_cost) # Why mean? See comment on sum_cost
        end
        if :slack_SOE_final_cost in propertynames(cost)
            sum_cost += sum(skipmissing(cost.slack_SOE_final_cost))
        end 
        if !isapprox(enriched_solution[:scalar].objective_value[1], sum_cost; rtol = parameters.MIPGap) 
            error("Start, operational cost and reserve penalization mismatch with objective value")
        end
    end
    cost_fields = [:start_cost_per_mw, :existing_cap_mw, :heat_rate_mmbtu_per_mwh, :fuel_cost, :var_om_cost_per_mwh, :fixed_om_cost_per_mw_per_hour]
    fields_to_remove = [:production_MW, :curtailment_MW, :commit, :start, :full_id, :shut]
    cost = leftjoin(
        enriched_solution[:generation],
        gen_df[!,union(cost_fields, [:r_id])],
        on = [:r_id]
        )

    cost.start_cost = cost.start_cost_per_mw .* cost.existing_cap_mw .* cost.start
    cost.production_cost = (cost.heat_rate_mmbtu_per_mwh .* cost.fuel_cost + cost.var_om_cost_per_mwh) .* cost.production_MW 
    cost.fixed_cost = cost.fixed_om_cost_per_mw_per_hour .* cost.existing_cap_mw .* replace(cost.commit, missing => 1)
    select!(cost,Not(union(cost_fields,fields_to_remove)))
    
    if :storage in keys(enriched_solution)
        cost_fields = [:var_om_cost_per_mwh]
        fields_to_remove = intersect([:charge_MW, :discharge_MW, :SOE_MWh, :envelope_up_MWh,:envelope_down_MWh, :full_id, :slack_SOE_final_MWh], propertynames(enriched_solution[:storage]))  
        storage_cost = leftjoin(
            enriched_solution[:storage],
            storage[!,union(cost_fields, [:r_id])],
            on = [:r_id],
        )
        storage_cost.production_cost =  (storage_cost.charge_MW + storage_cost.discharge_MW) .* storage_cost.var_om_cost_per_mwh
        if :slack_SOE_final_MWh in propertynames(storage_cost) 
            storage_cost.slack_SOE_final_cost = storage_cost.slack_SOE_final_MWh .* parameters.VSSOEFinal
        end
        select!(storage_cost, Not(union(cost_fields,fields_to_remove)))
        cost = vcat(cost, storage_cost, cols=:union)
    end
    if :reserve in keys(enriched_solution)
        fields_to_remove = [:reserve_up_MW, :reserve_down_MW, :full_id, :slack_reserve_up_MW, :slack_reserve_down_MW]
        reserve_cost = copy(enriched_solution[:reserve])
        reserve_cost.reserve_cost = (reserve_cost.reserve_up_MW + reserve_cost.reserve_down_MW)*parameters.VRESERVE
        min_hour = minimum(reserve_cost.hour)
        transform!(groupby(reserve_cost,[:hour]), # we multiply the slack variable by the their penalization cost at each :hour
            [:slack_reserve_up_MW, :hour] => ((x,y) -> x.*parameters.VSRESUP[y[1]-min_hour+1]) => :slack_reserve_up_cost, # hour-wise multiplication
            [:slack_reserve_down_MW, :hour] => ((x,y) -> x.*parameters.VSRESDN[y[1]-min_hour+1]) => :slack_reserve_down_cost # hour-wise multiplication
         )
        select!(reserve_cost, Not(fields_to_remove))
        cost = vcat(cost, reserve_cost, cols=:union)
    end

    if :energy_reserve in keys(enriched_solution)
        fields_to_remove = [:energy_reserve_up_MW, :energy_reserve_down_MW, :full_id, :slack_energy_reserve_up_MW, :slack_energy_reserve_down_MW]
        reserve_cost = copy(enriched_solution[:energy_reserve])
        reserve_cost.energy_reserve_cost = (reserve_cost.energy_reserve_up_MW + reserve_cost.energy_reserve_down_MW)*parameters.VRESERVE
        min_hour = minimum(reserve_cost.hour)
        transform!(groupby(reserve_cost,[:hour]), # we multiply the slack variable by the their penalization cost at each :hour
            [:slack_energy_reserve_up_MW, :hour] => ((x,y) -> x.*parameters.VSRESUP[y[1]-min_hour+1]) => :slack_energy_reserve_up_cost, # hour-wise multiplication
            [:slack_energy_reserve_down_MW, :hour] => ((x,y) -> x.*parameters.VSRESDN[y[1]-min_hour+1]) => :slack_energy_reserve_down_cost # hour-wise multiplication
         )
        select!(reserve_cost, Not(fields_to_remove)) 
        cost = vcat(cost, reserve_cost, cols=:union)
    end
    if :LOL_MW in propertynames(enriched_solution[:demand]) # ED, we assume that LGEN_MW is also present when LOL_MW is present
        fields_to_remove = [:LOL_MW, :LGEN_MW, :demand_MW]
        losses_cost = copy(enriched_solution[:demand])
        transform!(groupby(losses_cost, intersect([:scenario], propertynames(losses_cost))),
            :LOL_MW => (x -> x.*parameters.VLOL) => :LOL_cost,
            :LGEN_MW => (x -> x.*parameters.VLGEN) => :LGEN_cost      
         )
        # losses_cost.LOL_cost = losses_cost.LOL_MW .* parameters.VLOL
        # losses_cost.LGEN_cost = losses_cost.LGEN_MW .* parameters.VLGEN
        select!(losses_cost, Not(fields_to_remove))
        cost = vcat(cost, losses_cost, cols=:union) 
    end
    check_cost_consistency()
    # @warn "Cost consistency not checked" 
    return cost
end

function get_generation_parameters(gen_df)
    parameters_to_get = [:existing_cap_mw, :min_power]
    out = rename(copy(gen_df[!,union(FIELD_FOR_ENRICHING, parameters_to_get)]), :existing_cap_mw => :P_max_MW)
    sets = get_sets(gen_df)
    out.is_thermal = out.r_id .∈ Ref(sets.G_thermal)
    out.is_var = out.r_id .∈ Ref(sets.G_var)
    out.is_nt_nonvar = out.r_id .∈ Ref(sets.G_nt_nonvar)
    return out
end

function get_storage_parameters(storage)
    parameters_to_get = [:existing_cap_mw, :max_energy_mwh, :charge_efficiency, :discharge_efficiency, :initial_energy_proportion]
    return rename(storage[!,union(FIELD_FOR_ENRICHING, parameters_to_get)],[:existing_cap_mw, :max_energy_mwh] .=> [:P_max_MW, :SOE_max_MWh])
end

function change_type(df, froms, tos)
    out = df
    for (from,to) in zip(froms,tos)
        out = mapcols(x -> eltype(x) == from ? to.(x) : x, out)
    end
    return out
  end

function solution_to_parquet(s, file_name, file_folder)
    if any(!isempty, values(s)) && !isdir(file_folder)
        mkdir(file_folder) #  Create the folder if there is at least one nonempty df in values(s)
    end
    # if !isdir(file_folder) mkdir(file_folder) end
    # println("writing $(file_name)")
    println("writing $(file_folder)/$(file_name)")
    for (k,v) in zip(propertynames(s), s)
        if isempty(v)
            continue
        end
        Parquet2.writefile(joinpath(file_folder, file_name*"_"*string(k)*".parquet"), change_type(v, [Symbol, TerminationStatusCode, ResultStatusCode, Any], [string, string, string, string]))
    end
    # println(" ...done")
  end

function parquet_to_solution(file_name, file_folder, solution_keys=nothing)
    # TODO convert to TerminationStatusCode and ResultStatusCode
    if isnothing(solution_keys)
        solution_keys = SOLUTION_KEYS
    end
    keys = [k for k in solution_keys if isfile(joinpath(file_folder, file_name*"_"*string(k)*".parquet"))]
    println("reading...")
    aux = [read_parquet_and_convert(joinpath(file_folder, file_name*"_"*string(k)*".parquet")) for k in keys]
    println("...done")
    return NamedTuple(keys .=> aux)
end

function filter_infeasible_solutions(s)
    # We make use of the fact that only s.scalar has infeasible solutions
    # Returns feasible, infeasible solutions
    # Infeasible solutions have only scalar field
    filter_ = s.scalar.termination_status .== MOI.INFEASIBLE .|| isnothing.(s.scalar.termination_status) # WARNING: this condition must be aligned with unit_commitment.utils.is_non_feasible()
    return NamedTuple(k => k != :scalar ? v :  v[.!filter_, :] for (k,v) in pairs(s)), NamedTuple{(:scalar,)}((s.scalar[filter_, :],))
end