using Infiltrator
include("./model/pre_processing.jl")
include("./model/post_processing.jl")
include("./model/metrics.jl")
include("./model/unit_commitment/unit_commitment.jl")
include("./model/economic_dispatch.jl")
include("./notebooks/plotting.jl")
include("./notebooks/processing.jl")

# __revise_mode__ = :eval
# ENV["COLUMNS"]=120 # Set so all columns of DataFrames and Matrices are displayed
function plot_results(solution, required_reserve)
    supply, demand = calculate_supply_demand(solution)
    p1 = plot_fieldx_by_fieldy(supply, :production_MW, :resource)
    p2 = plot_fieldx_by_fieldy(demand, :demand_MW, :resource)
    p3 = plot()
    p4 = plot()
    p5 = plot()
    p6 = plot()
    has_reserve = false
    if haskey(solution,:energy_reserve)
        solution_reserve = solution.energy_reserve[solution.energy_reserve.hour.==solution.energy_reserve.hour_i,:]
        has_reserve = true
    elseif haskey(solution,:reserve)
        solution_reserve = copy(solution.reserve)
        has_reserve = true
    end
    if has_reserve
        reserve = calculate_reserve(solution_reserve, required_reserve)
        p3 = plot_reserve_by_fieldy(reserve, :reserve_up_MW, :resource)
        p4 = plot_reserve_by_fieldy(reserve, :reserve_down_MW, :resource)
    end

    if haskey(solution,:storage) & has_reserve
        battery_reserve = calculate_battery_reserve(solution.storage, solution_reserve)
        p5 = plot_battery_reserve_(battery_reserve, :reserve_up_MW_eff)
        p6 = plot_battery_reserve_(battery_reserve, :reserve_down_MW_eff)
    end
    [
        p1 p2
        p3 p4
        p5 p6
    ]
end


G_day = 7 # 68
G_RESERVE = 0.1
G_ε = 0.025
G_ρ = 0
G_input_folder = "./input/base_case_increased_storage_energy_v4.2"
# G_REMOVE_RESERVE_CONSTRAINTS = true
# G_CONSTRAIN_DISPATCH = true
# G_MAX_ITERATIONS = 100
# G_VRESERVE = 1e-6
# G_REMOVE_VARIABLES_FROM_OBJECTIVE = false


config = (
    ramp_constraints = true,
    # energy_reserve = required_energy_reserve,
    # energy_reserve = required_energy_reserve_cumulated,
    enriched_solution = true,
    
    # μ_up = 1,
    # μ_dn = 1,
)
  



function duc(;input_folder, day, kwargs...)
    # input_folder = get(kwargs, :input_folder, G_input_folder)
    # day = get(kwargs, :day, G_day)
    gen_df, loads_df, random_loads_df, gen_variable_df, storage_df, required_reserve = generate_deterministic_input_data(day, input_folder)
    storage_df.max_energy_mwh .=storage_df.max_energy_mwh*get(kwargs, :storage_max_energy_factor, 1)
    storage_df.existing_cap_mw .=storage_df.existing_cap_mw*get(kwargs, :storage_max_cap_factor, 1)
    config = (

        ramp_constraints = true,
        enriched_solution = true,
        storage = storage_df,
        reserve = required_reserve,
        storage_envelopes = true,
        get_dual_variables = true,
        mip_gap = get(kwargs, :mip_gap, 1e-8),
        # energy_reserve = generate_energy_reserve(day, input_folder, loads_df, gen_variable_df, G_ε, G_ρ),
        # energy_reserve = generate_energy_reserves_deprecated(required_reserve),
        # energy_reserve = generate_energy_reserves_cumulative(required_reserve),
        storage_link_constraint = false,
        μ_up = get(kwargs, :μ_up, 1),
        μ_dn = get(kwargs, :μ_dn, 1),
    )
    model= solve_unit_commitment(
        gen_df,
        loads_df,
        gen_variable_df;
        config...
        )
    return model, get_model_solution(model, gen_df, gen_variable_df; loads = loads_df, config...), required_reserve
end

function suc(;kwargs...)
    input_folder = get(kwargs, :input_folder, G_input_folder)
    day = get(kwargs, :day, G_day)
    expected_min_SOE = get(kwargs, :expected_min_SOE, false)
    gen_df, loads_df, random_loads_df, gen_variable_df, storage_df, required_reserve = generate_deterministic_input_data(day, input_folder)
    scenarios = load_scenarios(day, input_folder, loads_df, required_reserve)
    return solve_unit_commitment(
        gen_df,
        loads_df,
        gen_variable_df,
        scenarios;
        storage = storage_df,
        expected_min_SOE = expected_min_SOE,
        config...
        )
end

function ed(;kwargs...)
    input_folder = get(kwargs, :input_folder, G_input_folder)
    day = get(kwargs, :day, G_day)
    gen_df, loads_df, random_loads_df, gen_variable_df, storage_df, required_reserve = generate_deterministic_input_data(day, input_folder)
    solution  = solve_economic_dispatch_get_solution(
        duc(;kwargs...),
        gen_df,
        random_loads_df,
        gen_variable_df;
        config...
        )
    return solution
end


function merge_solutions_df(solution_name, solution_folders, folder_path)
    solution = [parquet_to_solution(solution_name, joinpath(folder_path, s)) for s in solution_folders]
    solution = NamedTuple(k => vcat([s[k] for s in solution if haskey(s, k)]...) for k in Set(union([keys(x) for x in solution]...)))
    return solution
end

function generate_post_processing_KPI_files(folder_path; stochastic = false, folders_to_read_ = nothing, save = true, chunk_size = 10)

    function check(gcdi_KPI_adequacy, gcdi_objective_function_KPI, group_by)
        # Check consistency in objective function
        x = sort(gcdi_KPI_adequacy, group_by)
        y = sort(gcdi_objective_function_KPI, group_by)
        if !(all(isapprox.(x.objective_value,  sum(eachcol(y[:,intersect([:OPEX, :LOL_cost, :LGEN_cost, :reserve_cost, :slack_reserve_up_cost, :slack_reserve_down_cost,:energy_reserve_cost, :slack_energy_reserve_up_cost, :slack_energy_reserve_down_cost], propertynames(y))])), rtol=10^-8)))
            error("Mismatch in objective value")
        end
        if !(all(isapprox.(x.OPEX,  y.OPEX , rtol=10^-8)))
            error("Mismatch in OPEX")
        end
    end

    function chunk_list_custom(arr, chunk_size)
        return [arr[i:min(i + chunk_size - 1, end)] for i in 1:chunk_size:length(arr)]
    end

    function vcat_namedtuples(nt_list)
        keys_all = unique(reduce(vcat, [collect(keys(nt)) for nt in nt_list]))
        out =  NamedTuple{Tuple(keys_all)}((vcat([get(nt, k, DataFrame()) for nt in nt_list]...) for k in keys_all))
        return NamedTuple(k => sort(v, :day) for (k, v) in pairs(out)) # ordering by day
    end

    function KPI_df_dict(solution_folders, folder_path, stochastic = false)
        keys_to_save = [
            :gcdi_KPI_adequacy,
            :gcd_KPI_adequacy,
            # :gcdi_KPI_objective_function,
            # :gcd_KPI_objective_function
            # :KPI_reserve,
            # :gcdi_KPI_reserve,
            # :gcd_KPI_reserve,
        ]

        println("Calculating KPIS...")
        aux = []
        # s_uc, s_ed = merge_solutions(solution_folders, folder_path, stochastic) # if stochastic == true, s_ed = nothing
        if !stochastic
            s_uc = merge_solutions_df("s_uc", solution_folders, folder_path)
            s_ed = merge_solutions_df("s_ed", solution_folders, folder_path)    
        else
            s_uc = nothing
            s_ed = merge_solutions_df("s_suc", solution_folders, folder_path)

        end

        if haskey(s_ed, :demand) # if solutions have converged, then this key should be present
            group_by =  intersect([:configuration, :day, :iteration, :scenario], propertynames(s_ed.demand)) # used only for checking
            push!(aux, calculate_adecuacy_gcdi_KPI(s_ed, s_uc))
            # aux[:gcdi_KPI_adequacy] = calculate_adecuacy_gcdi_KPI(s_ed, s_uc)
            push!(aux, calculate_adecuacy_gcd_KPI(last(aux)))
            # push!(aux, calculate_objective_function_gcdi_KPI(s_ed, s_uc,group_by)) # These KPIs are included in adequacy and are therefore not needed
            # push!(aux, calculate_objective_function_gcd_KPI(last(aux))) # These KPIs are included in adecuacy and are therefore not needed
            # calculate_reserve_KPI(s_ed, s_uc)
            # calculate_reserve_gcdi_KPI(aux[:KPI_reserve])
            # calculate_reserve_gcd_KPI(aux[:gcdi_KPI_reserve])
            check(aux[1], calculate_objective_function_gcdi_KPI(s_ed, s_uc,group_by), group_by)
            println("...done)")
            return NamedTuple(keys_to_save .=> aux)
        else
            return NamedTuple(keys_to_save .=> [DataFrame(), DataFrame()])
        end
    end

    folders_to_read = last.(splitpath.(filter(isdir, readdir(folder_path; join = true))))
    out_name = "all"
    if !isnothing(folders_to_read_)
        folders_to_read = intersect(folders_to_read_, folders_to_read)
        out_name = join(folders_to_read, "_")
    end

    if save
        solution_to_parquet(
            vcat_namedtuples([KPI_df_dict(folders, folder_path, stochastic) for folders in chunk_list_custom(folders_to_read, chunk_size)]),
            out_name,
            folder_path)
    end
    # return out
end

function generate_ed_solutions(;days, kwargs...)
    function generate_μ_configurations(μs) #   μs = [(μ_key = (up =::Vector, down=::Vector),)...]  # configuration name is for labeling purposes only
        mu_to_string(x) = isinteger(x) ? string(Int(x)) : replace(string(x), "." => "_")
        if isa(μs, NamedTuple) # if μs is a list of named tuples μs = [(μ_key = (up =::Vector, down=::Vector),)...]
            return [(key = Symbol("base_ramp_storage_envelopes_$(key)"), value = value) for (key, value) in pairs(μs)]
        else  # we assume is a list of values, μs =[float....] 
            return [(key = Symbol("base_ramp_storage_envelopes_up_$(mu_to_string(μ))_dn_$(mu_to_string(μ))"),  value = (up = μ, down = μ)) for μ in μs]
        end
    end

    folders = get(kwargs, :folders, [(get(kwargs, :input_folder, G_input_folder), get(kwargs, :output_folder, "./output"))])
    for (input_folder, output_folder) in folders
        for day in days
            generate_ed_solutions_([day], input_folder, output_folder, generate_μ_configurations(get(kwargs, :μs, nothing)); kwargs...)
        end
        generate_post_processing_KPI_files(output_folder, stochastic = false)
    end
end

function generate_ed_solutions_(days, input_folder, output_folder, μ_configurations; kwargs...)
    write = get(kwargs, :write, true)
    reserve = get(kwargs, :reserve, 0.1)
    ε = get(kwargs, :ε, 0.025)
    ρ = get(kwargs, :ρ, 0)
    energy_reserve = get(kwargs, :energy_reserve, false)
    # μs =  get(kwargs, :μs, nothing)
    add_to_config = Dict(
        :max_iterations => get(kwargs, :max_iterations, 100),
        :constrain_dispatch => get(kwargs, :constrain_dispatch, true),
        :VRESERVE => get(kwargs, :VRESERVE, 1e-6),
        # :remove_variables_from_objective => get(kwargs, :remove_variables_from_objective, false),
        # :VLOL => get(kwargs, :VLOL, 1e4),
        :mip_gap => get(kwargs, :mip_gap, 1e-8), 
        :VLGEN => get(kwargs, :VLGEN, 0),
        :VSRESUP => get(kwargs, :VSRESUP, 1e4),
        :VSRESDN => get(kwargs, :VSRESDN, 30),
        :thermal_reserve =>  get(kwargs, :thermal_reserve, false),
        :bidirectional_storage_reserve => get(kwargs, :bidirectional_storage_reserve, true),
        :constrain_SOE_by_envelopes => get(kwargs, :constrain_SOE_by_envelopes, false),
        # :naive_envelopes => get(kwargs, :naive_envelopes, false),
        :variables_to_constrain => get(kwargs, :variables_to_constrain, [:GEN]),
        # :storage_reserve_repartition =>  get(kwargs, :storage_reserve_repartition, 1),
        :get_dual_variables => get(kwargs, :get_dual_variables, false),
    )
    # configurations = vcat(configurations, [:base_ramp_storage_energy_reserve_cumulated])
    s_uc = Dict()
    s_ed = Dict()

    
    gen_df_, loads_df_, random_loads_df_, gen_variable_df_, storage_df, required_reserve, required_energy_reserve = generate_deterministic_input_data(input_folder)
    config = merge(add_to_config, generate_basic_configuration(storage_df, energy_reserve))
    uc_ = construct_unit_commitment(
        gen_df_;
        scenarios = nothing,
        config...
    )
    for day in days, μ_config in μ_configurations
        
        loads_df = filter_day(day, loads_df_)
        gen_variable_df = filter_day(day, gen_variable_df_)
        random_loads_df = filter_day(day, random_loads_df_)
        required_reserve = filter_day(day, required_reserve)
        required_energy_reserve = filter_day(day, required_energy_reserve)
        gen_df, loads_df, gen_variable_df = pre_process_load_gen_variable(gen_df_, loads_df, gen_variable_df)
        μ_up, μ_dn = pre_process_μ(μ_config.value.up, μ_config.value.down)
        
        uc = copy(uc_)
        initialize_model(uc, config[:mip_gap])
        update_time_dependent_data(uc, loads_df, gen_variable_df, storage_df, μ_up, μ_dn, required_reserve, required_energy_reserve, energy_reserve)
        optimize!(uc)
        
        s_uc[(day,μ_config.key)] = get_model_solution(uc, gen_df, gen_variable_df; loads = loads_df, config...)
        s_ed[(day,μ_config.key)] = solve_economic_dispatch_get_solution(
            uc,
            gen_df,
            random_loads_df,
            gen_variable_df;
            config...
        )
    end
    s_ed = merge_solutions(s_ed, [:day, :configuration])
    s_uc = merge_solutions(s_uc, [:day, :configuration])
    # s_uc = Dict(pairs(s_uc))
    if haskey(s_uc, :energy_reserve) 
        s_uc = merge(s_uc, 
            (reserve = vcat(get(s_uc, :reserve, DataFrame()), s_uc[:energy_reserve][s_uc[:energy_reserve].hour.==s_uc[:energy_reserve].hour_i,:][:,Not(:hour_i)]),)
        )
    end
    # s_uc = NamedTuple(s_uc)
    if write
        if !isdir(output_folder) mkpath(output_folder) end
        folder_path = joinpath(output_folder,"n_$(join(days,"-"))")
        solution_to_parquet(s_uc, "s_uc", folder_path)
        solution_to_parquet(s_ed, "s_ed", folder_path)
    end
    return s_uc, s_ed
end

function generate_suc_solutions(;days, kwargs...)
    function generate_suc_solutions_(day, input_folder, output_folder; kwargs...)
        gen_df, scenarios, gen_variable_df, storage_df = generate_stochastic_input_data(day, input_folder)
        #WARNING: gen_variable_df and gen_df generates a net generation asset that depends on the loads_df. If this load is negative, net generation will have some values different from zero.
        # scenarios = load_scenarios(day, input_folder, loads_df, required_reserve) #OBSERVATION: load_scenarios is filtering out the demand based on loads_df which itself is not necessarily the average across scenarios
        config = Dict(
            :storage => storage_df,
            :VLGEN => get(kwargs, :VLGEN, 0),
            :get_dual_variables => get(kwargs, :get_dual_variables, false),
            :mip_gap => get(kwargs, :mip_gap, 1e-8),
            )
        suc = solve_unit_commitment(
            gen_df,
            nothing,
            gen_variable_df,
            scenarios;
            expected_min_SOE = expected_min_SOE,
            config...
            )
        s_suc =  Dict(day => get_model_solution(suc, gen_df, gen_variable_df; scenarios = scenarios, config...)) # creation of this dictionary is needed for merge_solutions
        s_suc = merge_solutions(s_suc, [:day])
        if write
            if !isdir(output_folder) mkpath(output_folder) end
            folder_path = joinpath(output_folder,"n_$(join(day,"-"))")
            solution_to_parquet(s_suc, "s_suc", folder_path)
        end
    end
    write = get(kwargs, :write, true)
    expected_min_SOE = get(kwargs, :expected_min_SOE, false)    
    folders = get(kwargs, :folders, [(get(kwargs, :input_folder, nothing), get(kwargs, :output_folder, nothing))])
    for (input_folder, output_folder) in folders
        for day in days
            generate_suc_solutions_(day, input_folder, output_folder; kwargs...)
        end
        generate_post_processing_KPI_files(output_folder, stochastic = true)
    end

end

function run()
    days = [7]
    μs= [0, 0.2, 0.4, 0.6, 0.8, 1]
    # input_folder = "./input/base_case_increased_storage_energy_v7.0.4"
    input_folders =[
        ("./input/base_case_increased_storage_energy_v7.0", 0.0),
        ("./input/base_case_increased_storage_energy_v7.0.2", 0.2),
        ("./input/base_case_increased_storage_energy_v7.0.4", 0.4),
        ("./input/base_case_increased_storage_energy_v7.0.6", 0.6),
        ("./input/base_case_increased_storage_energy_v7.0.8", 0.8),
        ("./input/base_case_increased_storage_energy_v7.0.99", 0.99),
    ]
    # storage_reserve_repartitions = [0.0]
    storage_reserve_repartitions = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    energy_reserve = false
    for (input_folder,ρ) in input_folders, srr in storage_reserve_repartitions
        generate_ed_solutions(days = days, μs = μs, input_folder = input_folder, output_folder = "./output/solutions_v50.$(ρ).$(srr)s", energy_reserve = energy_reserve, storage_reserve_repartition = srr)
    end
end

# m_duc, s_duc, required_reserve = duc(input_folder = "./input/RTS-GMLC_v1.0", day = 7, storage_max_energy_factor = 1, storage_max_cap_factor = 1)
# # println(s_duc.dual_variables)
# plot_results(s_duc,required_reserve)