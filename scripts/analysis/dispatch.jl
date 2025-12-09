using PlotlyJS
using Infiltrator
include("../../model/pre_processing.jl")
include("../../model/post_processing.jl")
include("./plotting.jl")
include("./processing.jl")

function load_solutions_for_day(folder_path::String, day::Int)
    solution_folder = "n_$(day)"
    s_uc = parquet_to_solution("s_uc", joinpath(folder_path, solution_folder))
    s_ed = parquet_to_solution("s_ed", joinpath(folder_path, solution_folder))
    return s_uc, s_ed
end

function combine_namedtuples(solutions::Vector{NamedTuple}, keys)
    return NamedTuple(k => vcat([s[k] for s in solutions if haskey(s, k)]...) for k in keys)
end

function get_supply_demand(s, group_by)
    supply, demand = calculate_supply_demand(s, union([:hour, :resource], group_by))
    return supply, demand
end

function get_reserve(s_uc, group_by)
    if haskey(s_uc, :energy_reserve) && !isempty(s_uc.energy_reserve)
        s_uc_reserve = s_uc.energy_reserve[s_uc.energy_reserve.hour .== s_uc.energy_reserve.hour_i, :]
        s_uc_reserve = s_uc_reserve[:, Not(:hour_i)]
        rename!(s_uc_reserve, :energy_reserve_up_MW => :reserve_up_MW, :energy_reserve_down_MW => :reserve_down_MW)
        reserve_uc = calculate_reserve(s_uc_reserve, nothing, union([:hour, :resource], group_by))
    else
        reserve_uc = calculate_reserve(s_uc.reserve, nothing, union([:hour, :resource], group_by))
    end
    return reserve_uc
end

function get_commit(s_uc, s_ed, group_by)
    commit_uc = combine(groupby(s_uc.generation, [:resource, :configuration, :day, :hour]), :commit => sum => :commit)
    commit_ed = combine(groupby(s_ed.generation, [:resource, :configuration, :day, :iteration, :hour]), :commit => sum => :commit)
    return commit_uc, commit_ed
end

function get_battery_reserve(s_uc, reserve_uc)
    return calculate_battery_reserve(s_uc.storage, reserve_uc)
end

function run_dispatch_analysis(folder_path::String, day::Int)
    SOLUTION_KEYS = [:generation, :reserve, :storage, :energy_reserve, :demand] # Adjust as needed
    group_by = [:configuration, :day]

    # Load solutions
    s_uc, s_ed = load_solutions_for_day(folder_path, day)
    # @infiltrate
    # s_uc = combine_namedtuples([s_uc], SOLUTION_KEYS)
    # s_ed = combine_namedtuples([s_ed], SOLUTION_KEYS)

    # Supply and demand
    supply_uc, demand_uc = get_supply_demand(s_uc, group_by)
    supply_ed, demand_ed = get_supply_demand(s_ed, union([:iteration], group_by))

    # Reserve
    reserve_uc = get_reserve(s_uc, group_by)
    # reserve_ed = calculate_reserve(s_ed.reserve, nothing, union([:hour, :resource, :iteration], group_by))

    # Commitments
    commit_uc, commit_ed = get_commit(s_uc, s_ed, group_by)

    # Battery reserve
    battery_reserve_uc = get_battery_reserve(s_uc, reserve_uc)

    # You can add plotting or further analysis here

    # plot_supply_demand(supply_uc, demand_uc, supply_ed, demand_ed)
    # plot_commit(commit_uc, commit_ed)
    # plot_battery_reserve(battery_reserve_uc)

    return (
        supply_uc=supply_uc, demand_uc=demand_uc,
        supply_ed=supply_ed, demand_ed=demand_ed,
        reserve_uc=reserve_uc,
        commit_uc=commit_uc, commit_ed=commit_ed,
        battery_reserve_uc=battery_reserve_uc
    )
end


# day_ = 0
# iteration_ = :demand_1
# config_1 = unique(supply_uc.configuration)[1]
# config_2 = unique(supply_uc.configuration)[end]
# ;


# config_ = config_1
# supply_uc_ = supply_uc[(supply_uc.configuration .== config_) .& (supply_uc.day .== day_), :]
# demand_uc_ = demand_uc[(demand_uc.configuration .== config_) .& (demand_uc.day .== day_), :]
# reserve_uc_ = reserve_uc[(reserve_uc.configuration .== config_) .& (reserve_uc.day .== day_), :]
# plot_supply_demand(supply_uc_, demand_uc_, string(config_))


# Example usage:
# include("scripts/analysis/dispatch.jl")
# results = run_dispatch_analysis("output/RTS-GMLC_v32.3s", 131)
# plot_supply_demand(results.supply_uc, results.demand_uc)