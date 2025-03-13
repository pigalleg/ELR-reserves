using CSV
using DataFrames
using Infiltrator
include("../post_processing.jl") # parquet_to_solution
include("../metrics.jl")

G_dem_prec = 2

function update_input_file(SOE_last, input_name)
    println("Updating $(input_name)...")
    folder_path = "input"

    # Read the existing output CSV file
    file_to_write = joinpath(folder_path, input_name, "uc", "Storage_data.csv")
    output_df = CSV.read(file_to_write, DataFrame)

    # Update the 'final_energy_proportion' column based on 'r_id'
    select!(output_df, Not(:final_energy_proportion))
    output_df.final_energy_proportion .= 0.0
    # Reorder SOE_last according to the order of r_id in output_df
    for row in eachrow(SOE_last[:, [:r_id, :SOC]])
        output_df[output_df.R_ID .== row[:r_id], :final_energy_proportion] .= round(row[:SOC], digits=G_dem_prec)
    end

    # Write the updated DataFrame back to the CSV file
    CSV.write(file_to_write, output_df)
    println("done")
end

function get_SOC_last(solution_name, day, mu)
    function create_SOE(s_ed, s_uc)
        SOE = copy(s_ed.storage[!, [:configuration, :day, :iteration, :hour, :r_id, :SOE_MWh]])
        leftjoin!(SOE,
                  unique(s_uc.storage_parameters[!, [:r_id, :SOE_max_MWh, :initial_energy_proportion]]),
                  on = [:r_id])

        transform!(SOE, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu)
        sort!(SOE, :mu)
        SOE.SOC = SOE.SOE_MWh ./ SOE.SOE_max_MWh
        return SOE
    end

    folder_path = "output"
    s_uc = parquet_to_solution("s_uc", joinpath(folder_path, solution_name, "n_$(day)"))
    s_ed = parquet_to_solution("s_ed", joinpath(folder_path, solution_name, "n_$(day)"))
    SOE = create_SOE(s_ed, s_uc)
    SOE = filter(x -> (x.day .== day) & (x.mu .== mu), SOE)
    SOE_mean = combine(groupby(SOE, [:r_id, :hour]), [:SOC] .=> mean, renamecols = false)
    SOC_last = combine(groupby(sort(SOE_mean, :hour), [:r_id]), [:SOC] .=> last, renamecols = false) # manually checked that this operation gives the right input
    return SOC_last
end

function update_final_energy_proportion(; kwargs...)
    from_solution = get(kwargs, :from_solution, nothing)
    day = get(kwargs, :day, 7)
    to_input = get(kwargs, :to_input, nothing)
    mu = get(kwargs, :mu, 1)
    println("Extracting SOC last from $(from_solution)...")
    SOE_last = get_SOC_last(from_solution, day, mu)
    update_input_file(SOE_last, to_input)
end

function main()
    rhos = [0.5, 0.6, 0.7, 0.8, 0.9, 0.99]
    from_solutions = ["solutions_v57.$(r).4s" for r in rhos]
    mus = [0.38, 0.37, 0.49, 0.55, 0.65, 0.97]
    to_input = ["base_case_increased_storage_energy_v8.$(r).4" for r in rhos]

    for (x, y, z) in zip(from_solutions, mus, to_input)
        update_final_energy_proportion(from_solution = x, day = 7, mu = y, to_input = z)
    end
end
