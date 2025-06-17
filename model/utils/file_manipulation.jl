using CSV
using DataFrames
using Infiltrator
include("../post_processing.jl") # parquet_to_solution
include("../metrics.jl")

G_dem_prec = 2
G_output_folder_path = "../../output"
G_input_folder_path = "../../input"

function update_storage_final_energy_file(SOE_last, day, input_name)
    println("Updating $(input_name)...")
    
    # Read the existing output CSV file
    file_to_write = joinpath(G_input_folder_path, input_name, "uc", "Storage_final_energy.csv")
    output_df = CSV.read(file_to_write, DataFrame)

    # Check if the day already exists in the DataFrame
    if day in output_df.day
        # Update the 'final_energy_proportion' column for the given day
        # select!(output_df, Not(:final_energy_proportion))
        for row in eachrow(SOE_last[:, [:r_id, :SOC]])
            mask = (output_df.r_id .== row[:r_id]) .& (output_df.day .== day)
            output_df[mask, :final_energy_proportion] .= row[:SOC]
        end
    else
        # Append new rows for the new day
        new_rows = DataFrame(r_id = SOE_last.r_id,
                             final_energy_proportion = SOE_last.SOC,
                             day = fill(day, nrow(SOE_last)))
        output_df = vcat(output_df, new_rows)
    end
    # Write the updated DataFrame back to the CSV file
    CSV.write(file_to_write, output_df)
    println("done")
end

function update_storage_data_file(SOE_last, input_name) # Deprecated
    println("Updating $(input_name)...")

    # Read the existing output CSV file
    file_to_write = joinpath(G_input_folder_path, input_name, "uc", "Storage_data.csv")
    output_df = CSV.read(file_to_write, DataFrame)

    # Update the 'final_energy_proportion' column based on 'r_id'
    select!(output_df, Not(:final_energy_proportion))
    output_df.final_energy_proportion .= 0.0
    # Reorder SOE_last according to the order of r_id in output_df
    for row in eachrow(SOE_last[:, [:r_id, :SOC]])
        output_df[output_df.r_id .== row[:r_id], :final_energy_proportion] .= row[:SOC]
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

    
    s_uc = parquet_to_solution("s_uc", joinpath(G_output_folder_path, solution_name, "n_$(day)"))
    s_ed = parquet_to_solution("s_ed", joinpath(G_output_folder_path, solution_name, "n_$(day)"))
    SOE = create_SOE(s_ed, s_uc)
    SOE = filter(x -> (x.day .== day) & (x.mu .== mu), SOE)
    SOE_mean = combine(groupby(SOE, [:r_id, :hour]), [:SOC] .=> mean, renamecols = false)
    SOC_last = combine(groupby(sort(SOE_mean, :hour), [:r_id]), [:SOC] .=> last, renamecols = false) # manually checked that this operation gives the right input
    return SOC_last
end

function update_final_energy_proportion(update_storage_data_file; from_solution, day, mu = 1, to_input, )
    println("Extracting SOC last from $(from_solution)...")
    SOE_last = get_SOC_last(from_solution, day, mu)
    if update_storage_data_file
        println("Updating storage data file...")
        update_storage_data_file(SOE_last, to_input)  
    else
        println("Updating storage final energy file...")
        update_storage_final_energy_file(SOE_last, day, to_input)
    end
end

function main_ESA()
    rhos = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.99]
    from_solutions = ["solutions_v57.$(r).4s" for r in rhos]
    mus = [0.3, 0.3, 0.32, 0.32, 0.37, 0.38, 0.37, 0.49, 0.55, 0.65, 0.97]
    to_input = ["base_case_increased_storage_energy_v8.$(r).4.1" for r in rhos]
    for (x, y, z) in zip(from_solutions, mus, to_input)
        update_final_energy_proportion(true, from_solution = x, day = 7, mu = y, to_input = z, )
    end
end

function main_RTS()
    days = [1, 2, 3]
    from_solution = "RTS-GMLC_v5.0s"
    mus = [0.62,0.48,0.6]
    to_input = "RTS-GMLC_v1.1"
    for (mu, day) in zip(mus, days)
        update_final_energy_proportion(false, from_solution = from_solution, day = day, mu = mu, to_input = to_input)
    end
end