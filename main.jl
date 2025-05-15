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

# function load_configuration(storage_df, required_reserve)
#     config = (
#         mip_gap = G_MIP_GAP,
#         ramp_constraints = true,
#         storage = storage_df,
#         # reserve = required_reserve,
#         # energy_reserve = required_energy_reserve,
#         # energy_reserve = required_energy_reserve_cumulated,
#         enriched_solution = true,
#         # storage_envelopes = true,
#         # μ_up = 1,
#         # μ_dn = 1,
#     )                   
#     return config
# end

function load_deterministic_data(day, input_folder, ε=nothing, ρ=nothing)
    gen_df, loads_multi_df, gen_variable_multi_df, storage_df, random_loads_multi_df = generate_input_data(day, input_folder)
    # required_reserve = generate_reserves(loads_multi_df, gen_variable_multi_df, reserve)
    file = joinpath(input_folder, G_UC_DATA, "Reserve.csv")
    if isfile(file)
        println("Reserve file found, loading reserves...")                            
        required_reserve = filter_day(day, CSV.read(file, DataFrame))
    else
        println("Reserve file not found, generating reserves...")
        required_reserve = generate_reserves(loads_multi_df, gen_variable_multi_df, ε, ρ)
    end
    random_loads_multi_df = filter_demand(loads_multi_df, random_loads_multi_df, required_reserve)
    return gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve
end

function load_energy_reserve(day, input_folder, loads_multi_df, gen_variable_multi_df, ε, ρ)
    file = joinpath(input_folder, G_UC_DATA, "Energy reserve.csv")
    if isfile(file)
        println("Energy reserve file found, loading reserves...")
        return filter_day(day, CSV.read(file, DataFrame))
    else
        println("Energy reserve file not found, generating reserves...")
        return  generate_energy_reserves(loads_multi_df, gen_variable_multi_df, ε, ρ)
    end
end

function load_scenarios(day, input_folder, loads_multi_df, required_reserve)
    scenarios = generate_scenarios_data(day, input_folder)
    scenarios = (demand = filter_demand(loads_multi_df, scenarios.demand, required_reserve), probability = scenarios.probability)
    return scenarios
end

function duc(;input_folder, day, kwargs...)
    # input_folder = get(kwargs, :input_folder, G_input_folder)
    # day = get(kwargs, :day, G_day)
    gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve = load_deterministic_data(day, input_folder, G_ε, G_ρ)
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
        # energy_reserve = load_energy_reserve(day, input_folder, loads_multi_df, gen_variable_multi_df, G_ε, G_ρ),
        # energy_reserve = generate_energy_reserves_deprecated(required_reserve),
        # energy_reserve = generate_energy_reserves_cumulative(required_reserve),
        storage_link_constraint = false,
        μ_up = get(kwargs, :μ_up, 1),
        μ_dn = get(kwargs, :μ_dn, 1),
    )
    model= solve_unit_commitment(
        gen_df,
        loads_multi_df,
        gen_variable_multi_df;
        config...
        )
    return model, get_model_solution(model, gen_df, gen_variable_multi_df; loads = loads_multi_df, config...), required_reserve
end

function suc(;kwargs...)
    input_folder = get(kwargs, :input_folder, G_input_folder)
    day = get(kwargs, :day, G_day)
    expected_min_SOE = get(kwargs, :expected_min_SOE, false)
    gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve = load_deterministic_data(day, input_folder, G_ε, G_ρ)
    scenarios = load_scenarios(day, input_folder, loads_multi_df, required_reserve)
    return solve_unit_commitment(
        gen_df,
        loads_multi_df,
        gen_variable_multi_df,
        scenarios;
        storage = storage_df,
        expected_min_SOE = expected_min_SOE,
        config...
        )
end

function ed(;kwargs...)
    input_folder = get(kwargs, :input_folder, G_input_folder)
    day = get(kwargs, :day, G_day)
    gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve = load_deterministic_data(day, input_folder, G_ε, G_ρ)
    solution  = solve_economic_dispatch_get_solution(
        duc(;kwargs...),
        gen_df,
        random_loads_multi_df,
        gen_variable_multi_df;
        config...
        )
    return solution
end


function merge_solutions_df(solution_name, solution_folders, folder_path)
    solution = [parquet_to_solution(solution_name, joinpath(folder_path, s)) for s in solution_folders]
    solution = NamedTuple(k => vcat([s[k] for s in solution if haskey(s, k)]...) for k in Set(union([keys(x) for x in solution]...)))
    return solution
end

function generate_post_processing_KPI_files(folder_path; stochastic = false, folders_to_read_ = nothing, save = true)
    
    function check(gcdi_KPI_adequacy, gcdi_objective_function_KPI, group_by)
        # Check consistency in objective function
        x = sort(gcdi_KPI_adequacy, group_by)
        y = sort(gcdi_objective_function_KPI, group_by)
        if !(all(isapprox.(x.objective_value,  sum(eachcol(y[:,intersect([:OPEX, :LOL_cost, :LGEN_cost, :reserve_cost], propertynames(y))])), rtol=10^-8)))
            error("Missmatch in objective value")
        end
        if !(all(isapprox.(x.OPEX,  y.OPEX , rtol=10^-8)))
            error("Missmatch in OPEX")
        end
    end

    function chunk_list_custom(arr, chunk_size)
        return [arr[i:min(i + chunk_size - 1, end)] for i in 1:chunk_size:length(arr)]
    end

    function KPI_df_dict(solution_folders, folder_path, stochastic = false)
        println("Calculating KPIS...")
        out = []
        # s_uc, s_ed = merge_solutions(solution_folders, folder_path, stochastic) # if stochastic == true, s_ed = nothing
        if !stochastic
            s_uc = merge_solutions_df("s_uc", solution_folders, folder_path)
            s_ed = merge_solutions_df("s_ed", solution_folders, folder_path)    
        else
            s_uc = nothing
            s_ed = merge_solutions_df("s_suc", solution_folders, folder_path)

        end 
        group_by =  intersect([:configuration, :day, :iteration, :scenario], propertynames(s_ed.demand)) # used only for checking
       
        push!(out, calculate_adecuacy_gcdi_KPI(s_ed, s_uc))
        # out[:gcdi_KPI_adequacy] = calculate_adecuacy_gcdi_KPI(s_ed, s_uc)
        push!(out, calculate_adecuacy_gcd_KPI(last(out)))
        push!(out, calculate_objective_function_gcdi_KPI(s_ed, s_uc,group_by)) # These KPIs are included in adequacy and are therefore not needed
        # push!(out, calculate_objective_function_gcd_KPI(last(out))) # These KPIs are included in adecuacy and are therefore not needed
        # calculate_reserve_KPI(s_ed, s_uc)
        # calculate_reserve_gcdi_KPI(out[:KPI_reserve])
        # calculate_reserve_gcd_KPI(out[:gcdi_KPI_reserve])
        check(out[1], out[3], group_by)
        println("...done)")
        return out

    end
    chunk_size = 1
    values = [[],[],[],[],[]]

    folders_to_read = last.(splitpath.(filter(isdir, readdir(folder_path; join = true))))
    out_name = "all"
    if !isnothing(folders_to_read_)
        folders_to_read = intersect(folders_to_read_, folders_to_read)
        out_name = join(folders_to_read, "_")
    end
    keys = [
        :gcdi_KPI_adequacy,
        :gcd_KPI_adequacy,
        # :gcdi_KPI_objective_function,
        # :gcd_KPI_objective_function
        # :KPI_reserve,
        # :gcdi_KPI_reserve,
        # :gcd_KPI_reserve,
        ]
    values = vcat.([KPI_df_dict(folders, folder_path, stochastic) for folders in chunk_list_custom(folders_to_read, chunk_size)]...)
    out = NamedTuple(k => v for (k,v) in zip(keys, values))
    if save
        solution_to_parquet(out, out_name, folder_path)
    end
    return out
end

function generate_ed_solutions(;days, kwargs...)
    function generate_multipliers_configurations(μs) #   μs = [(μ_key = (up =::Vector, down=::Vector),)...]  # configuration name is for labeling purposes only
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
            generate_ed_solutions_([day], input_folder, output_folder, generate_multipliers_configurations(get(kwargs, :μs, nothing)); kwargs...)
        end
        generate_post_processing_KPI_files(output_folder, stochastic = false)
    end
end

function generate_ed_solutions_(days, input_folder, output_folder, configurations; kwargs...)
    function get_reference_configuration(k, configurations)
        i = first(findall(x->x == k , configurations))
        return i > 1 ?  getindex(configurations, i-1) : nothing
    end
    write = get(kwargs, :write, true)
    reserve = get(kwargs, :reserve, 0.1)
    ε = get(kwargs, :ε, 0.025)
    ρ = get(kwargs, :ρ, 0)
    energy_reserve = get(kwargs, :energy_reserve, false)
    alternative_solution = get(kwargs, :alternative_solution, false)
    # μs =  get(kwargs, :μs, nothing)
    add_config = Dict(
        :max_iterations => get(kwargs, :max_iterations, 100),
        # :constrain_dispatch => get(kwargs, :constrain_dispatch, true),
        :VRESERVE => get(kwargs, :VRESERVE, 1e-6),
        # :remove_variables_from_objective => get(kwargs, :remove_variables_from_objective, false),
        # :VLOL => get(kwargs, :VLOL, 1e4),
        :mip_gap => get(kwargs, :mip_gap, 1e-8), 
        :VLGEN => get(kwargs, :VLGEN, 0),
        :thermal_reserve =>  get(kwargs, :thermal_reserve, false),
        :bidirectional_storage_reserve => get(kwargs, :bidirectional_storage_reserve, true),
        :constrain_SOE_by_envelopes => get(kwargs, :constrain_SOE_by_envelopes, false),
        # :naive_envelopes => get(kwargs, :naive_envelopes, false),
        :variables_to_constrain => get(kwargs, :variables_to_constrain, [:GEN]),
        :storage_reserve_repartition =>  get(kwargs, :storage_reserve_repartition, 1),
        :get_dual_variables => get(kwargs, :get_dual_variables, false),
    )
    # configurations = vcat(configurations, [:base_ramp_storage_energy_reserve_cumulated])
    s_uc = Dict()
    s_ed = Dict()
    for day in days, config_ in configurations

        gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve = load_deterministic_data(day, input_folder, ε, ρ)
        required_energy_reserve = load_energy_reserve(day, input_folder, loads_multi_df, gen_variable_multi_df, ε, ρ)
        if energy_reserve
            config = merge(add_config, generate_configuration(config_.value.up, config_.value.down, storage_df, energy_reserve = required_energy_reserve))
        else
            config = merge(add_config, generate_configuration(config_.value.up, config_.value.down, storage_df, reserve = required_reserve))
        end
        k_reference = get_reference_configuration(config_, configurations)
        if !isnothing(k_reference) & alternative_solution # if reference_solution is added, both uc and ed are will be solved with alternative model
            config = merge((reference_solution = s_uc[(day,k_reference)],), config)
        end
        uc = solve_unit_commitment(
            gen_df,
            loads_multi_df,
            gen_variable_multi_df;
            config...
        )
        s_uc[(day,config_.key)] = get_model_solution(uc, gen_df, gen_variable_multi_df; loads = loads_multi_df, config...)
        s_ed[(day,config_.key)] = solve_economic_dispatch_get_solution(
            uc,
            gen_df,
            random_loads_multi_df,
            gen_variable_multi_df;
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
        
        gen_df, loads_multi_df, random_loads_multi_df, gen_variable_multi_df, storage_df, required_reserve = load_deterministic_data(day, input_folder, G_ε, G_ρ)
        scenarios = load_scenarios(day, input_folder, loads_multi_df, required_reserve)
        config = Dict(
            :storage => storage_df,
            :VLGEN => get(kwargs, :VLGEN, 0),
            :get_dual_variables => get(kwargs, :get_dual_variables, false),
            :mip_gap => get(kwargs, :mip_gap, 1e-8),
            )
        suc = solve_unit_commitment(
            gen_df,
            loads_multi_df,
            gen_variable_multi_df,
            scenarios;
            expected_min_SOE = expected_min_SOE,
            config...
            )
        s_suc =  get_model_solution(suc, gen_df, gen_variable_multi_df; scenarios = scenarios, config...)
        # merge_solutions(s_suc, [:day])
        if write
            if !isdir(output_folder) mkpath(output_folder) end
            folder_path = joinpath(output_folder,"n_$(join(day,"-"))")
            solution_to_parquet(s_suc, "s_suc", folder_path)
        end
    end
    write = get(kwargs, :write, true)
    expected_min_SOE = get(kwargs, :expected_min_SOE, false)    
    folders = get(kwargs, :folders, [(get(kwargs, :input_folder, nothing), get(kwargs, :output_folder, nothing))])
    for (input_folder, output_folder) in folders, day in days
        generate_suc_solutions_(day, input_folder, output_folder; kwargs...)
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