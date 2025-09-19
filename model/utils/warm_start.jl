using JuMP, CSV, DataFrames

function save_solution_to_csv(model::Model, filename::String)
    folder = dirname(filename)
    if !isdir(folder)
        mkpath(folder)
    end
    vars = all_variables(model)
    df = DataFrame(
        variable = [name(v) for v in vars],
        value = value.(vars)
    )
    CSV.write(filename, df)
    println("Solution saved to $filename")
end

# Add model_type flag to the filename (e.g., .../day_162_config_1_uc.csv or ..._ed.csv)
function save_solution(model::Model, output_folder, day, config_id; model_type::Union{Symbol,String} = :uc)
    tag = lowercase(String(model_type))
    filename = joinpath(output_folder, "warm_start", "day_$(day)_config_$(config_id)_$(tag).csv")
    save_solution_to_csv(model, filename)
end

function load_solution_from_csv(model::Model, filename::String)
    df_loaded = CSV.read(filename, DataFrame)
    vars = all_variables(model)
    name_to_var = Dict(name(v) => v for v in vars)

    present_mask = [haskey(name_to_var, row.variable) for row in eachrow(df_loaded)]
    missing_cnt = count(!, present_mask)
    if missing_cnt > 0
        @warn "Skipping $(missing_cnt) variables not present in current model"
    end
    sel = df_loaded[present_mask, :]
    set_start_value.(
        [name_to_var[row.variable] for row in eachrow(sel)],
        sel.value
    )
    println("Warm start applied from $filename (assigned $(nrow(sel)) variables)")
end

# Load with optional model_type flag; tries flagged filename first, then falls back to legacy name
function load_solution(model, input_folder, day, config_id; model_type::Union{Nothing,Symbol,String} = nothing)
    base_dir = joinpath(input_folder, "warm_start")
    legacy = joinpath(base_dir, "day_$(day)_config_$(config_id).csv")
    cand = String[]

    if model_type === nothing
        # Try both ED then UC, then legacy
        push!(cand, joinpath(base_dir, "day_$(day)_config_$(config_id)_ed.csv"))
        push!(cand, joinpath(base_dir, "day_$(day)_config_$(config_id)_uc.csv"))
        push!(cand, legacy)
    else
        tag = lowercase(String(model_type))
        push!(cand, joinpath(base_dir, "day_$(day)_config_$(config_id)_$(tag).csv"))
        push!(cand, legacy)  # fallback for backward compatibility
    end

    for f in cand
        if isfile(f)
            println("Loading warm start from: $f")
            return load_solution_from_csv(model, f)
        end
    end

    println("Warm start file in $input_folder does not exist. Skipping warm start.")
    return
end