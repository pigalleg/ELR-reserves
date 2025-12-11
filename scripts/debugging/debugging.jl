using JuMP, MathOptInterface, CSV
# Ref: https://jump.dev/JuMP.jl/stable/manual/solutions/#Conflicts
# if get_attribute(model, MOI.ConflictStatus()) == MOI.CONFLICT_FOUND
#     iis_model, _ = copy_conflict(model)
#     print(iis_model)
# end

function get_conflicting_constraints(model)
    # optimize!(model)
    compute_conflict!(model)
    list_of_conflicting_constraints = ConstraintRef[]
    for (F, S) in list_of_constraint_types(model)
        for con in all_constraints(model, F, S)
            if get_attribute(con, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
                push!(list_of_conflicting_constraints, con)
            end
        end
    end
    return list_of_conflicting_constraints
end

function save_constraints_status(model, append)
    reg = r"\w*\[(.+)\]"
    names = []
    idx_1 = []
    idx_2 = []
    exprs = []
    slacks = []
    count_1 = 0
    count_2 = 0
    for (F, S) in list_of_constraint_types(model)
        for ci in all_constraints(model, F, S)
            slack = F!= JuMP.VariableRef ? abs(normalized_rhs(ci) - value(ci)) <= 1e-5 : missing
            name = MOI.get(model, MOI.ConstraintName(), ci)
            index = match(reg, name)
            indices = ["nothing", "nothing"]
            if !isnothing(index)
                for (index, value) in enumerate(collect(split(index[1],",")))
                    indices[index] = value
                end
            end
            push!(names, name)
            push!(idx_1, indices[1])
            push!(idx_2, indices[2])
            push!(exprs, string(ci))
            push!(slacks, slack)
        end
    end
    out = DataFrame(name = names, idx_1 = idx_1, idx_2 = idx_2, expression = exprs, active_slack = slacks)
    CSV.write("active_constraints_$append.csv", out)
    # @infiltrate
end

function save_model_to_file(model, name)
    write_to_file(model, "$name.mof.json") #".lp"

end


function save_list_to_file(list, name)
    f = open("$name.txt", "w")
    for i in list
        println(f, i)
    end
end

function relax_reserve_requirement(model, reserve, VLRESERVE= 1e8) 
    # ResUpRequirement = model[:ResUpRequirement]
    # ResDnRequirement = model[:ResDnRequirement]
    T = axes(model[:RESUP])[2]
    G_reserve = axes(model[:RESUP])[1]
    remove_variable_constraint(model, :ResUpRequirement)
    remove_variable_constraint(model, :ResDnRequirement)
    RESUP = model[:RESUP]
    RESDN = model[:RESDN]

    @variables(model, begin
        LRESUP[T] >= 0
        LRESDN[T] >= 0
    end)

    @objective(model, Min, 
        objective_function(model) + VLRESERVE*sum(LRESUP[t] + LRESDN[t] for t in T)
    )
    @constraint(model, ResUpRequirement[t in T],
        sum(RESUP[g,t] for g in G_reserve) >= reserve[reserve.hour .== t,:reserve_up_MW][1] - LRESUP[t]
    )
    @constraint(model, ResDnRequirement[t in T],
        sum(RESDN[g,t] for g in G_reserve) >= reserve[reserve.hour .== t,:reserve_down_MW][1] - LRESDN[t]
    )
end



#  CSV.write("fixed_variables_r.csv", DataFrame([(name(v), fix_value(v)) for v in all_variables(model) if is_fixed(v)]))

using DataFrames, Parquet2, Statistics, Printf

read_parquet(path) = try DataFrame(Parquet2.readfile(path)) catch; nothing end

# Case-insensitive token match; return Symbol
function find_col(df::DataFrame, tokens::Vector{String})
    for c in names(df)
        s = lowercase(String(c))
        if any(t -> occursin(t, s), tokens)
            return Symbol(c)
        end
    end
    return nothing
end

# Numeric column helper
isnumericcol(df::DataFrame, c::Symbol) = Base.nonmissingtype(eltype(df[!, c])) <: Real

# Ensure there is a :hour column (rename or synthesize)
function normalize_hour!(df::DataFrame)
    if :hour ∈ names(df)
        return df
    end
    h = find_col(df, ["hour","t","time","hour_i","period","slot","h","k","step"])
    if h !== nothing && h != :hour && !(:hour ∈ names(df))
        rename!(df, h => :hour)
    elseif h === nothing
        df[!, :hour] = collect(1:nrow(df))
    end
    return df
end

# Sum total generation by hour
function sum_generation_by_hour(gen::DataFrame)
    gen = normalize_hour!(gen)
    gcol = find_col(gen, ["production_mw","gen_mw","power_mw","p_mw","generation"])
    if gcol !== nothing
        df = select(gen, [:hour, gcol])
        return combine(groupby(df, :hour), gcol => (x -> sum(skipmissing(x))) => :supply_MW)
    else
        numcols = [c for c in names(gen) if c != :hour && isnumericcol(gen, c)]
        isempty(numcols) && return DataFrame(hour=Int[], supply_MW=Float64[])
        df = select(gen, [:hour; numcols])
        long = stack(df, numcols; variable_name=:var, value_name=:val)
        return combine(groupby(long, :hour), :val => (x -> sum(skipmissing(x))) => :supply_MW)
    end
end

function diagnose_LOL_day(day::Int; out_root::String)
    root = joinpath(out_root, "n_$(day)")
    if !isdir(root)
        println("Folder not found: $root"); return nothing
    end
    files = readdir(root; join=true)

    i_demand = findfirst(f->occursin("demand", lowercase(f)) && occursin("s_ed", lowercase(f)), files)
    i_gen    = findfirst(f->occursin("generation", lowercase(f)) && occursin("s_ed", lowercase(f)), files)
    i_scalar = findfirst(f->occursin("scalar", lowercase(f)) && occursin("s_ed", lowercase(f)), files)
    i_duals  = findfirst(f->occursin("dual", lowercase(f)) && occursin("s_ed", lowercase(f)), files)

    demand_path = isnothing(i_demand) ? nothing : files[i_demand]
    gen_path    = isnothing(i_gen)    ? nothing : files[i_gen]
    scalar_path = isnothing(i_scalar) ? nothing : files[i_scalar]
    duals_path  = isnothing(i_duals)  ? nothing : files[i_duals]

    println("Found files:")
    println("  demand: ", demand_path)
    println("  gen   : ", gen_path)
    println("  scalar: ", scalar_path)
    println("  duals : ", duals_path)

    demand = isnothing(demand_path) ? nothing : read_parquet(demand_path)
    gen    = isnothing(gen_path)    ? nothing : read_parquet(gen_path)
    scalar = isnothing(scalar_path) ? nothing : read_parquet(scalar_path)
    duals  = isnothing(duals_path)  ? nothing : read_parquet(duals_path)

    if demand === nothing || gen === nothing
        println("Missing s_ed_demand/generation parquet in $root")
        println("All files:"); foreach(println, files); return nothing
    end

    normalize_hour!(demand); normalize_hour!(gen)
    dcol   = find_col(demand, ["demand_mw","demand","load"])
    lolcol = find_col(demand, ["lol"])
    lgcol  = find_col(demand, ["lgen","curtail"])

    gen_sum = sum_generation_by_hour(gen)

    # Select available columns (except demand; we will inject it)
    selcols = intersect([:hour, lolcol, lgcol], names(demand))
    d = select(demand, selcols; copycols=true)

    # Ensure :hour present
    if !(:hour ∈ names(d))
        d[!, :hour] = demand[!, :hour]
    end

    # Rename LOL/LGEN to canonical if present
    if lolcol !== nothing && lolcol ∈ names(d) && lolcol != :LOL
        if :LOL ∈ names(d); select!(d, Not(:LOL)); end
        rename!(d, lolcol => :LOL)
    end
    if lgcol !== nothing && lgcol ∈ names(d) && lgcol != :LGEN
        if :LGEN ∈ names(d); select!(d, Not(:LGEN)); end
        rename!(d, lgcol => :LGEN)
    end
    # Ensure optional columns exist and are numeric
    for c in (:LOL, :LGEN)
        if !(c ∈ names(d))
            d[!, c] = zeros(Float64, nrow(d))
        else
            d[!, c] = coalesce.(d[!, c], 0.0)
        end
    end

    # Inject canonical demand column (fallback to zeros if absent)
    if dcol !== nothing && dcol ∈ names(demand)
        d[!, :demand_MW] = coalesce.(demand[!, dcol], 0.0)
    else
        println("Warning: Demand column not found. Using zeros.")
        d[!, :demand_MW] = zeros(Float64, nrow(d))
    end

    # Join and compute imbalance
    df = leftjoin(d, gen_sum, on=:hour)
    if !(:supply_MW ∈ names(df)); df[!, :supply_MW] = zeros(Float64, nrow(df)); end
    df[!, :supply_MW] = coalesce.(df[!, :supply_MW], 0.0)
    df[!, :imbalance] = df[!, :supply_MW] .+ df[!, :LOL] .- df[!, :LGEN] .- df[!, :demand_MW]

    bad = df[df[!, :LOL] .> 1e-6, [:hour, :demand_MW, :supply_MW, :LGEN, :LOL, :imbalance]]
    println("\nHours with LOL > 0 for day $day:")
    if nrow(bad) == 0
        println("None.")
    else
        show(bad; allcols=true, truncatelines=false); println()
    end

    if scalar !== nothing
        println("\nScalar/objective snapshot:")
        show(first(scalar, min(10, nrow(scalar))); allcols=true, truncatelines=false); println()
    end
    if duals !== nothing
        println("\nDuals snapshot:")
        show(first(duals, min(10, nrow(duals))); allcols=true, truncatelines=false); println()
    end

    return df
end