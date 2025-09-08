using DataFrames
using Parquet2
using MathOptInterface: TerminationStatusCode
using Statistics
include("../model/pre_processing.jl")
order_ = [
  "solar_photovoltaic_curtailment",
  "onshore_wind_turbine_curtailment",
  "small_hydroelectric_curtailment",
  "loss_of_generation",
  "total_loss_of_load_ED",
  "total_loss_of_generation_ED",
  "net_generation_curtailment",
  "battery",
  "net_generation",
  
  "CSP",
  "CC", 
  "CT",
  "STEAM", 
  "ROR", "HYDRO",
  "NUCLEAR",
  

  "solar_photovoltaic",
  "natural_gas_fired_combustion_turbine",
  "natural_gas_fired_combined_cycle",
  "onshore_wind_turbine",
  "hydroelectric_pumped_storage",
  "small_hydroelectric",
  "biomass",
  "total",
  "system",
  "required"]


G_NET_GENERAION_FULL_ID = "net_generation"

function order_df(df_)
  df = copy(df_)
  df[!, :order_] = indexin(df[!,:resource], order_)
  replace!(df[!,:order_], nothing =>length(order_))
  sort!(df, :order_, rev = true)
  return select(df, Not(:order_))
end


function calculate_supply_demand(solution, group_by = [:hour, :resource] )
  #Supply-demand computation
  # group_by = intersect(propertynames(solution.generation),[:hour, :resource, :iteration])
  demand = combine(groupby(solution.demand, group_by), :demand_MW => sum, renamecols=false)
  # replace!(aux.curtailment_MW, missing => 0)
  if :LOL_MW in propertynames(solution.demand)
    aux = combine(groupby(solution.demand, group_by), :LOL_MW => sum, renamecols=false)
    aux = aux[aux.LOL_MW.>0,:]
    rename!(aux, :LOL_MW => :demand_MW)
    transform!(aux, :resource .=> ByRow(x -> x*"_loss_of_load_ED") => :resource)
    append!(demand, aux, promote = true)
  end
  if :LGEN_MW in propertynames(solution.demand)
    aux = combine(groupby(solution.demand, group_by), :LGEN_MW => sum, renamecols=false)
    aux = aux[aux.LGEN_MW.>0,:]
    rename!(aux, :LGEN_MW => :demand_MW)
    transform!(aux, :resource .=> ByRow(x -> x*"_loss_of_generation_ED") => :resource)
    append!(demand, aux, promote = true)
  end
  supply = combine(groupby(solution.generation, group_by), :production_MW => sum, renamecols=false)
  aux = combine(groupby(solution.generation, group_by), :curtailment_MW => sum, renamecols=false)
  # replace!(aux.curtailment_MW, missing => 0)
  aux = aux[aux.curtailment_MW.>0,:]
  rename!(aux, :curtailment_MW => :production_MW)
  transform!(aux, :resource .=> ByRow(x -> x*"_curtailment") => :resource)
  append!(supply, aux, promote = true)

  

  if haskey(solution,:storage)
      aux = combine(groupby(coalesce.(solution.storage,0), group_by), [:discharge_MW => sum, :charge_MW => sum], renamecols=false) #we can do coalesce because we are summing
      rename!(aux, [:discharge_MW => :production_MW, :charge_MW => :demand_MW])
      append!(supply, aux[!, push!(copy(group_by), :production_MW)])
      append!(demand,  aux[!,push!(copy(group_by), :demand_MW)], promote = true)
  end 
  return order_df(supply), order_df(demand)
end

function calculate_reserve(reserve, required_reserve = nothing, group_by_ = [:hour, :resource])
  field_up_dn = [:reserve_up_MW,:reserve_down_MW]
  aux = reserve[!,union(group_by_, field_up_dn)]
  replace!([aux.reserve_up_MW, missing => 0, aux.reserve_up_MW, missing => 0])
  # replace!(aux.reserve_down_MW, missing => 0)
  group_by = intersect(propertynames(aux), group_by_)
  reserve = combine(groupby(aux, group_by), [field_up_dn[1] => sum, field_up_dn[2] => sum], renamecols=false)
   # TODO: Adapt the following lines to consider the cases where group_by has more keys (e.g. :iteration, :coniguration)
  if !isnothing(required_reserve) 
    aux = copy(required_reserve)
    aux = aux[!,union(intersect(propertynames(aux), group_by_),field_up_dn)]
    aux.resource.= "required"
    append!(reserve, aux)
  end
  return order_df(reserve)
end

function calculate_battery_reserve(solution_storage, solution_reserve, efficiency = 0.92)
  # TODO: adapt when input dfs have more keys (e.g., :iteration, configuration)
  variables_to_get = [:r_id, :hour, :SOE_MWh, :reserve_up_MW, :reserve_down_MW, :envelope_up_MWh, :envelope_down_MWh, :iteration]
  
  fields_storage = intersect(propertynames(solution_storage), variables_to_get)
  fields_solution_reserve = intersect(propertynames(solution_reserve), variables_to_get)
  group_by = intersect([:r_id, :hour, :iteration], fields_storage, fields_solution_reserve)
  out = innerjoin(
      solution_storage[!,fields_storage], 
      solution_reserve[solution_reserve.resource .=="battery", fields_solution_reserve], 
      on = intersect(fields_storage, fields_storage, group_by))
  out = combine(groupby(out, setdiff(group_by, [:r_id])), Not(setdiff(group_by, [:r_id])) .=> sum, renamecols=false)
  out.reserve_down_MW_eff .= out.reserve_down_MW*efficiency
  out.reserve_up_MW_eff .= -out.reserve_up_MW*1/efficiency
  return out
end

parse_configuration_to_mu(x) = !isnothing(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))) ? parse(Float64, replace(match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", string(x))[1], "_" => ".")) : 1

function load_deterministic_data(day, input_folder, ε=nothing, ρ=nothing)
  gen_df, loads_multi_df, gen_variable_multi_df, storage_df, random_loads_multi_df = generate_deterministic_input_data(day, input_folder)
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

function load_energy_reserve(day, input_folder, loads_multi_df, gen_variable_multi_df, ε = nothing, ρ = nothing)
  file = joinpath(input_folder, G_UC_DATA, "Energy reserve.csv")
  if isfile(file)
      println("Energy reserve file found, loading reserves...")
      return filter_day(day, CSV.read(file, DataFrame))
  else
      println("Energy reserve file not found, generating reserves...")
      return  generate_energy_reserves(loads_multi_df, gen_variable_multi_df, ε, ρ)
  end
end
