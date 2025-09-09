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

function save_solution(model::Model, output_folder, day, config_id)
    filename = joinpath(output_folder, "warm_start", "day_$(day)_config_$(config_id).csv")  
    save_solution_to_csv(model, filename)
end

function load_solution_from_csv(model::Model, filename::String)
    df_loaded = CSV.read(filename, DataFrame)
    vars = all_variables(model)
    name_to_var = Dict(name(v) => v for v in vars)

    set_start_value.(
        [name_to_var[row.variable] for row in eachrow(df_loaded)],
        df_loaded.value
    )
    println("Warm start applied from $filename")
end

function load_solution(model, input_folder, day, config_id)
    filename = joinpath(input_folder, "warm_start", "day_$(day)_config_$(config_id).csv")  
    load_solution_from_csv(model, filename)
end