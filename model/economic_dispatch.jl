using JuMP
using Gurobi
using DataFrames

include("./unit_commitment/unit_commitment.jl")

function get_variable_base_name(variable)
    return Symbol(match(r"([A-z]+)\[", name(first(variable)))[1])
end

function get_reserves_variables(model)
    prepend = haskey(model, :ERESUP)
    prepend_E(symbol_name, prepend) = !prepend ? symbol_name : Symbol("E"*string(symbol_name))
    return Dict(
        :res_up_var => prepend_E(:RESUP, prepend),
        :res_up_var_value => value.(model[prepend_E(:RESUP, prepend)]),
        :res_dn_var => prepend_E(:RESDN, prepend),
        :res_dn_var_value => value.(model[prepend_E(:RESDN, prepend)]),
        :res_up_ch_var => prepend_E(:RESUPCH, prepend),
        :res_up_ch_var_value => value.(model[prepend_E(:RESUPCH, prepend)]),
        :res_up_dis_var =>  prepend_E(:RESUPDIS, prepend),
        :res_up_dis_var_value => value.(model[prepend_E(:RESUPDIS, prepend)]),
        :res_dn_ch_var =>  prepend_E(:RESDNCH, prepend),
        :res_dn_ch_var_value => value.(model[prepend_E(:RESDNCH, prepend)]), 
        :res_dn_dis_var =>  prepend_E(:RESDNDIS, prepend),
        :res_dn_dis_var_value => value.(model[prepend_E(:RESDNDIS, prepend)]), 
    )
end

function get_envelope_variables(model)
    variables = [:SOEUP, :SOEDN, :ESOEUP, :ESOEDN]
    return [(var, value.(model[var])) for var in variables if haskey(model, var)]
end

function get_variables_to_fix(model)
    variables_to_fix =  [:COMMIT, :START, :SHUT,:RESUP, :RESDN, :ERESUP, :ERESDN, :SRESDN, :SRESUP, :SERESDN, :SERESUP]
    return [(var, value.(model[var])) for var in variables_to_fix if haskey(model, var)]
end

function get_variables_to_constrain(model; kwargs...)
    variables_to_constrain = get(kwargs, :variables_to_constrain, [:GEN])
    constrain_SOE_by_envelopes = get(kwargs, :constrain_SOE_by_envelopes, false)
    if constrain_SOE_by_envelopes
        variables_to_constrain = [:GEN]
        println("variables_to_constrain set to [:GEN] because constrain_SOE_by_envelopes is true")
    end
    return [(var, value.(model[var])) for var in variables_to_constrain] 
end

function construct_economic_dispatch(gen_df; kwargs... )
    VLOL = get(kwargs, :VLOL, 1e4)
    VLGEN = get(kwargs, :VLGEN, 0)
    storage = get(kwargs, :storage, nothing)
    ramp_constraints = get(kwargs, :ramp_constraints, true)
    sets =  get_sets(gen_df)
    mip_gap = get(kwargs, :mip_gap, 1e-8)
    constrain_SOE_by_envelopes = get(kwargs, :constrain_SOE_by_envelopes, false)
    
    ed = ED(gen_df, VLOL, VLGEN, mip_gap)
    if !isnothing(storage)
        println("Adding storage...")
        add_storage(ed, storage, sets, SOE_final = false)
        add_envelope_parameters(ed) # needs to be declared before constraint_SOE_final_to_envelopes and constrain_SOE_to_envelopes
        constraint_SOE_final_to_envelopes(ed)
        if constrain_SOE_by_envelopes
            constrain_SOE_to_envelopes(ed)
        end
    end
    if ramp_constraints
        println("Adding ramp constraints...")   
        add_ramp_constraints(ed, gen_df, sets)
    end
    return ed
end


function ED(gen_df, VLOL, VLGEN, mip_gap)
    println("Constructing ED...")
    # Outputs EC by fixing variables of UC
    ed = Model()
    initialize_model(ed, mip_gap)

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
    @variable(ed, extra_OV in Parameter(0))
    @variable(ed, p_DEMAND[t in T] in Parameter(0.0)) # time-dependent data
    @variable(ed, p_MAX_GEN[g in G_var, T in T] in Parameter(0.0)) # time-dependent data
    @variable(ed, VLOL[t in keys(VLOL)] in Parameter(VLOL[t])) # for post-processing purposes
    @variable(ed, VLGEN[t in keys(VLGEN)] in Parameter(VLGEN[t])) # for post-processing purposes
     @variables(ed, begin
        GEN[G, T]  >= 0 # generation
        COMMIT[G_thermal, T], Bin # commitment status (Bin=binary)
        START[G_thermal, T], Bin  # startup decision
        SHUT[G_thermal, T], Bin   # shutdown decision
    end)

    @variables(ed, begin 
        LOL[T] >= 0
        LGEN[T] >= 0
        end)

    @expression(ed, StartCost,
        sum(gen_df[gen_df.r_id .== g,:start_cost_per_mw][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*START[g,t] for g in G_thermal for t in T)
    )

    @expression(ed, OperationalCost,
        sum((gen_df[gen_df.r_id .== g,:heat_rate_mmbtu_per_mwh][1]*gen_df[gen_df.r_id .== g,:fuel_cost][1] + gen_df[gen_df.r_id .== g,:var_om_cost_per_mwh][1])*GEN[g,t] for g in G_nonvar for t in T) +
        sum(gen_df[gen_df.r_id .== g,:var_om_cost_per_mwh][1]*GEN[g,t]  for g in G_var for t in T) + 
        sum(gen_df[gen_df.r_id .== g,:fixed_om_cost_per_mw_per_hour][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1]*COMMIT[g,t] for g in G_thermal for t in T) + 
        sum(gen_df[gen_df.r_id .== g,:fixed_om_cost_per_mw_per_hour][1]*gen_df[gen_df.r_id .== g,:existing_cap_mw][1] for g in G_nt_nonvar for t in T)
    )
    
    @expression(ed, OPEX,
        OperationalCost + StartCost
    )

    @objective(ed, Min, 
        OPEX + sum(LOL[t]*VLOL[t] + LGEN[t]*VLGEN[t] for t in T) + extra_OV
    )

    @expression(ed, SupplyDemand[t in T],
        sum(GEN[g,t] for g in G) + LOL[t] - LGEN[t]
    )

    @constraint(ed, SupplyDemandBalance[t in T], # Update of p_DEMAND constraint is performed within the Monte Carlo loop
        SupplyDemand[t] == p_DEMAND[t]
    )

    add_capacity_constraints(ed, gen_df, sets)
    println("...done")
    return ed
end

function update_dispatch_restrictions(ed, reserve_variables, variables_to_constrain, variables_to_fix; kwargs...)
    bidirectional_storage_reserve = get(kwargs, :bidirectional_storage_reserve, true)
    constrain_dispatch = get(kwargs, :constrain_dispatch, true)
    remove_variables_from_objective = get(kwargs, :remove_variables_from_objective, false)
    constrain_by_energy =  reserve_variables[:res_up_var] == :ERESUP
    constrain_decision_variables(ed, reserve_variables, variables_to_constrain, constrain_dispatch, constrain_by_energy, bidirectional_storage_reserve)
    fix_decision_variables(ed, variables_to_fix, remove_variables_from_objective)
end

function update_envelope_parameters(model, envelope_variables, energy_envelope)
    if !energy_envelope
        p_SOEUP = envelope_variables[1][2]
        p_SOEDN = envelope_variables[2][2]
    else
        # For energy reserves, we reduce the dimension of the envelopes ESOEUP (envelope_variables[1][2]) and ESOEDN (envelope_variables[2][2]) in oneby taking max(ESOEUP[s,:,t]) and min(ESOEDN[s,:,t]). This operation is not supported natively by DenseAxisArray, so we convert to DataFrame and then a Matrix
        p_SOEUP = transform(value_to_df_(envelope_variables[1][2]))
        p_SOEUP = combine(groupby(p_SOEUP,[:r_id,:hour]), :value => maximum, renamecols = false) # maximum value for each r_id and hour
        p_SOEUP = convert_to_matrix(p_SOEUP, :r_id, :hour, :value) # convert to matrix
        
        p_SOEDN = transform(value_to_df_(envelope_variables[2][2]))
        p_SOEDN = combine(groupby(p_SOEDN,[:r_id,:hour]), :value => minimum, renamecols = false)
        p_SOEDN = convert_to_matrix(p_SOEDN, :r_id, :hour, :value)
    end    
    update_parameter_value(model, :p_SOEUP, p_SOEUP)
    update_parameter_value(model, :p_SOEDN, p_SOEDN)
end

function constrain_decision_variables(model, reserve_variables, variables_to_constrain, constrain_dispatch, constrain_by_energy, bidirectional_storage_reserve)
    # If constrain_dispatch = true, it constraints the dispatch variables (up to three: :GEN, :CH and :DIS) according to the reserve procured at UC stage.
    # Variables that do not have a reserve or energy reserve element associated will be fixed to their value at UC stage.
    # If constrain_dispatch = false, units providing reserve or energy reserve will not have their dispatched constrained, but not providing reserves will have their dispatch fixed to the value at UC stage.
    # If bidirectional_storage_reserve = true, it will consider that the reserve is provided by the storage unit in both charging modes.
    # It will also constrain variables in variables_to_constrain according to the reserve procured at UC stage.
    if constrain_dispatch # assumes either ERESUP or RESUP exists
        constrain_dispatch_variables_according_to_reserve(model, bidirectional_storage_reserve, variables_to_constrain, constrain_by_energy; reserve_variables...)
    end
    constraint_dispatch_variables_with_no_reserve(model, bidirectional_storage_reserve, variables_to_constrain, constrain_by_energy; reserve_variables...) # By default, units not offering reserve will have their dispatch fixed.
end

function constraint_dispatch_variables_with_no_reserve(model, bidirectional_storage_reserve, variables_to_constrain, constrain_by_energy; kwargs...)
    function fix_variables_to_value(var_name, var_value, res_vars_value, constrain_by_energy)
    
        G = [constrain_by_energy ? [g for (g,j,t) in eachindex(res_var)] : axes(res_var)[1] for res_var in res_vars_value] # We take the set of assets that have reserve or energy reserve (res_vars) procured
        G = reduce(intersect, union(G, [axes(var_value)[1]])) # We also intersect with the set of assets belonging to var
        G_to_fix = setdiff(axes(var_value)[1], G)
        model_var = model[var_name]
        for key in collect(keys(var_value)) if key.I[1] in G_to_fix
                fix(model_var[key], var_value[key], force = true) # force is needed because the variable has bounds defined.
            end
        end
    end

    if bidirectional_storage_reserve
        gen_logic_group = [:GEN]
        dis_logic_group = [:DIS]
        ch_logic_group = [:CH]
        ch_logic_group_2 = []
    else
        gen_logic_group = [:GEN, :DIS]
        dis_logic_group = []
        ch_logic_group = []
        ch_logic_group_2 = [:CH]
    end
    for (var_name, var_value) in variables_to_constrain
        if var_name in gen_logic_group
            fix_variables_to_value(var_name, var_value, [kwargs[:res_up_var_value], kwargs[:res_dn_var_value]], constrain_by_energy)
        elseif var_name in dis_logic_group
            fix_variables_to_value(var_name, var_value, [kwargs[:res_up_dis_var_value], kwargs[:res_dn_dis_var_value]], constrain_by_energy)
        elseif var_name in ch_logic_group
            fix_variables_to_value(var_name, var_value, [kwargs[:res_dn_ch_var_value], kwargs[:res_up_ch_var_value]], constrain_by_energy)
        elseif var_name in ch_logic_group_2
            fix_variables_to_value(var_name, var_value, [kwargs[:res_dn_var_value], kwargs[:res_up_var_value]], constrain_by_energy)
        end 
    end
end

function constrain_dispatch_variables_according_to_reserve(model, bidirectional_storage_reserve, variables_to_constrain, constrain_by_energy; kwargs...)
    #TODO: declare following constraints during the ED construction and update them through parameters instead of redefining them at each loop.
    # Dispatch constrained based on the procured reserve or energy reserve at the UC stage
    # Function fixes up to three variable types: :GEN, :CH and :DIS
    # If Constrain_by_energy= true, integral of redispatch in [j,t] is constrained by the respective energy reserve term. Otherwise, constraints are pointwise.
    function constrain_production_variables(model, var_name, var_value, res_up_var_name, res_up_var_value, constrain_by_energy; lower_bound = false)
        # This same function is used to constraints :GEN, :CH and :DIS variables 
        T = axes(var_value)[2]
        name = Symbol("$(string(var_name))$(string(res_up_var_name))")
        c = !lower_bound ? 1 : -1
        model_var = model[var_name]
        if haskey(model, name)
            println("Constraint $name already exists....")
            remove_variable_constraint(model, name, true) # remove previous constraint if exists
        end
        if !constrain_by_energy
            G = intersect(axes(res_up_var_value)[1], axes(var_value)[1])
            model[name] = @constraint(model, [g in G, t in T], 
                c*model_var[g,t] <= c*var_value[g,t] + res_up_var_value[g,t]
            )
            for g in G, t in T # important to identify constraints for deletion at each loop
                set_name(model[name][g,t], string(name)*"[$g,$t]")
            end
        else
            G = [g for (g,j,t) in eachindex(res_up_var_value)]
            G = intersect(G, axes(var_value)[1])
            model[name] = @constraint(model,[g in G, j in T, t in T; j <= t],
                sum(c*(model_var[g,tt] - var_value[g,tt]) for tt in T if (tt >= j)&(tt <= t)) <= + res_up_var_value[g,j,t]
            )
            for g in G, j in T, t in T if j<=t # important to identify constraints for deleting at each loop
                    set_name(model[name][g,j,t], string(name)*"[$g,$j,$t")
                end
            end
        end
    end

    println("Constraining dispatch to procured reserve...")
    if bidirectional_storage_reserve
        gen_logic_group = [:GEN]
        dis_logic_group = [:DIS]
        ch_logic_group = [:CH]
        ch_logic_group_2 = []
    else
        gen_logic_group = [:GEN, :DIS]
        dis_logic_group = []
        ch_logic_group = []
        ch_logic_group_2 = [:CH]
    end
    for (var_name, var_value) in variables_to_constrain
        if var_name in gen_logic_group
            constrain_production_variables(model, var_name, var_value, kwargs[:res_up_var], kwargs[:res_up_var_value], constrain_by_energy)
            constrain_production_variables(model, var_name, var_value, kwargs[:res_dn_var], kwargs[:res_dn_var_value], constrain_by_energy, lower_bound = true)
        elseif var_name in dis_logic_group
            constrain_production_variables(model, var_name, var_value, kwargs[:res_up_dis_var], kwargs[:res_up_dis_var_value], constrain_by_energy)
            constrain_production_variables(model, var_name, var_value, kwargs[:res_dn_dis_var], kwargs[:res_dn_dis_var_value], constrain_by_energy, lower_bound = true)
        elseif var_name in ch_logic_group
            constrain_production_variables(model, var_name, var_value, kwargs[:res_dn_ch_var], kwargs[:res_dn_ch_var_value], constrain_by_energy)
            constrain_production_variables(model, var_name, var_value, kwargs[:res_up_ch_var], kwargs[:res_up_ch_var_value], constrain_by_energy, lower_bound = true)

        elseif var_name in ch_logic_group_2
            constrain_production_variables(model, var_name, var_value, kwargs[:res_dn_var], kwargs[:res_dn_var_value], constrain_by_energy)
            constrain_production_variables(model, var_name, var_value, kwargs[:res_up_var], kwargs[:res_up_var_value], constrain_by_energy, lower_bound = true)
        end
    end
end


function add_envelope_parameters(model)
    println("Adding envelope parameters...")
    SOE = model[:SOE]
    S = axes(SOE)[1]
    T_incr = axes(SOE)[2]
    @variable(model, p_SOEUP[s in S, t in T_incr] in Parameter(0.0)) 
    @variable(model, p_SOEDN[s in S, t in T_incr] in Parameter(0.0))
end

function constrain_SOE_to_envelopes(model)
    println("Constraining SOE...")
    SOE = model[:SOE]
    S = axes(SOE)[1]
    T_incr = axes(SOE)[2]
    p_SOEUP = model[:p_SOEUP]
    p_SOEDN = model[:p_SOEDN]
    @constraint(model, SOEEnvelopeUP[s in S, t in T_incr],
        SOE[s,t] <= p_SOEUP[s,t]
    )
    @constraint(model, SOEEnvelopeDN[s in S, t in T_incr],
        SOE[s,t] >= p_SOEDN[s,t]
    )
end

function constraint_SOE_final_to_envelopes(model)
    println("Constraining SOE final to envelopes...")
    SOE = model[:SOE]
    S = axes(SOE)[1]
    T_incr = axes(SOE)[2]
    p_SOEUP = model[:p_SOEUP]
    p_SOEDN = model[:p_SOEDN]
    @constraint(model, SOEFinalUp[s in S],
        SOE[s,T_incr[end]] <= p_SOEUP[s,T_incr[end]]
    )
    @constraint(model, SOEFinalDn[s in S],
        SOE[s,T_incr[end]] >= p_SOEDN[s,T_incr[end]]
    )
end

function fix_decision_variables(model, variables, remove_variables_from_objective = true)
    println("Fixing decision variables...")
    for (var_name, var_value) in variables
        # Check if this variable exists in the current model
        if haskey(model, var_name)
            model_var = model[var_name]
            # Fix variables in the current model using values from the other model
            for key in collect(eachindex(model_var))
                fix(model_var[key], var_value[key]; force = !is_binary(model_var[key]))
                if remove_variables_from_objective 
                    println("Removing fixed decision variables from objective...")
                    set_objective_coefficient(model, model_var[key], 0)
                end
            end
        else
            println("Variable $var_name not found in model - skipping")
        end
    end
end


function solve_economic_dispatch_(ed, gen_df, loads, gen_variable; kwargs...)
    print("Solving ED...")
    optimize!(ed)
    if !is_solved_and_feasible(ed)
        print("model not solved or feasible.")
        return get_nonfeasbile_model_information(ed)
    end
    println("done")
    return get_model_solution(ed, gen_df, gen_variable; loads = loads, kwargs...)
end


function launch_monte_carlo_get_solution(ed, gen_df, loads, gen_variable; kwargs...)
    max_iterations = get(kwargs, :max_iterations, 100)
    solutions = Dict()
    kwargs = Dict(kwargs)
    # At this point one idea would be to copy several instances of ed so all of them use the same input solution from uc
    for k in first(propertynames(loads[!, Not([:hour,:day])]), max_iterations)
        println("")
        println("Montecarlo iteration: $k")
        gen_df_k, loads_df_k, gen_variable_k = pre_process_load_gen_variable(gen_df, rename(loads[!,[:hour,k]], k=>:demand), gen_variable) # remove negative net load to convert it into net generation asset
        update_parameter_value(ed, :p_DEMAND, loads_df_k[:,:demand])
        update_parameter_value(ed, :p_MAX_GEN, convert_to_matrix(gen_variable_k, :r_id, :hour, :max_production_mw))
        solutions[k] = solve_economic_dispatch_(ed, gen_df_k, loads_df_k, gen_variable_k; kwargs...)
    end
    return merge_solutions(solutions)
end

