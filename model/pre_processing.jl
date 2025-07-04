using DataFrames
using CSV
using Distributions
using LinearAlgebra

g_DEFAULT_LOCATION = "./input/base_case"
g_NET_GENERAION_FULL_ID = "net_generation"
g_UC_DATA = "uc"

# --- start pre_processing ---
function variance(σ, ρ)
  # For autocorrelated errors X[t+1] = ρ*X[t] + (1-ρ^2)^(1/2)*N(0,σ[t])
  # then var(X[t]) = ρ^2*var(X[t-1]) + (1-ρ^2)*σ[t]^2, with var(X[0]) = σ[0]^2
  var = Vector{Float64}(undef,  length(σ))
  var[1] = σ[1]^2
  for i in 2:length(var)
    var[i] = ρ^2*var[i-1] + (1-ρ^2)* σ[i]^2f
  end
  return var
end

function get_var(timeseries, ρ, p, margin = 0.1)
  σ = abs.(timeseries*margin./quantile(Normal(),p))
  σ = reshape(σ,(24,:))
  return mapslices(x->variance(x, ρ), σ, dims=1)
end

function to_GMT(df) # deprecated
  # Convert from GMT to GMT-8
  df.hour = mod.(df.hour .- 9, 8760) .+ 1
  sort!(df, :hour)
end

function read_data(input_location, shift_timezone = false)
  input_uc_data_location = joinpath(input_location, g_UC_DATA)
  gen_info = CSV.read(joinpath(input_uc_data_location,"Generators_data.csv"), DataFrame)
  fuels = CSV.read(joinpath(input_uc_data_location,"Fuels_data.csv"), DataFrame)
  loads = CSV.read(joinpath(input_uc_data_location,"Demand.csv"), DataFrame)
  gen_variable = CSV.read(joinpath(input_uc_data_location,"Generators_variability.csv"), DataFrame)
  storage_info = CSV.read(joinpath(input_uc_data_location,"Storage_data.csv"), DataFrame)
  storage_final_energy_path = joinpath(input_uc_data_location, "Storage_final_energy.csv")
  storage_final_energy = isfile(storage_final_energy_path) ? CSV.read(storage_final_energy_path, DataFrame) : nothing
  # storage_final_energy = CSV.read(joinpath(input_uc_data_location,"Storage_final_energy.csv"), DataFrame)
  # rename all columns to lowercase (by convention)
  files_to_lowercase = [gen_info, fuels, loads, gen_variable, storage_info]
  if storage_final_energy !== nothing
    push!(files_to_lowercase, storage_final_energy)
  end
  for f in files_to_lowercase
      rename!(f,lowercase.(names(f)))
  end
  if shift_timezone
    to_GMT(gen_variable)
    to_GMT(loads)
  end
  return gen_info, fuels, loads, identity.(gen_variable), storage_info, storage_final_energy
end

function generate_deterministic_input_data(input_location, day = nothing)
  gen_info, fuels, loads_df, gen_variable_info, storage_info, storage_final_energy = read_data(input_location)
  gen_df = pre_process_generators_data(gen_info, fuels)
  gen_df, loads_df, gen_variable_df  = pre_process_load_gen_variable(gen_df, loads_df, pre_process_gen_variable(gen_df, gen_variable_info))
  storage_df = pre_process_storage_data(storage_info)
  # storage_df = pre_process_storage_data(storage_info, day, storage_final_energy)
  random_loads_df = read_random_demand(input_location)
  required_reserve = generate_reserves(input_location)
  required_energy_reserve = generate_energy_reserve(input_location)

  # Day filtering
  if !isnothing(day)
      loads_df = filter_day(day, loads_df)
      gen_variable_df = filter_day(day, gen_variable_df)
      random_loads_df = filter_day(day, random_loads_df)
  end

  # Random loads filtering according to reserves
  random_loads_df = filter_demand(loads_df, random_loads_df, required_reserve)
  
  transform_to_internal_time(loads_df)
  transform_to_internal_time(gen_variable_df)
  transform_to_internal_time(random_loads_df)
  return gen_df, loads_df, random_loads_df, gen_variable_df, storage_df, required_reserve, required_energy_reserve
end

function generate_stochastic_input_data(day, input_location = g_DEFAULT_LOCATION)
  gen_info, fuels, loads_df, gen_variable_info, storage_info, storage_final_energy = read_data(input_location)
  gen_df = pre_process_generators_data(gen_info, fuels)
  gen_variable_df  = pre_process_gen_variable(gen_df, gen_variable_info)
  storage_df = pre_process_storage_data(storage_info, day, storage_final_energy)
  required_reserve = generate_reserves(day, input_location)
  scenarios_demand, scenarios_probaility = generate_scenarios_data(input_location)

  #Day filtering
  if !isnothing(day)
      loads_df = filter_day(day, loads_df) # needed to filter for clipping acording to reserves
      gen_variable_df = filter_day(day, gen_variable_df)
      scenarios_demand = filter_day(day, scenarios_demand) 
  end
  scenarios_demand = filter_demand(loads_df, scenarios_demand, required_reserve)
  gen_df, scenarios_demand, gen_variable_df = pre_process_scenarios_demand_gen_variable(gen_df, scenarios_demand, gen_variable_df)
  scenarios = (demand = scenarios_demand, probability = scenarios_probaility)
  return gen_df, scenarios, gen_variable_df, storage_df
end 

function generate_reserves(input_location)
  out = CSV.read(joinpath(input_location, g_UC_DATA, "Reserve.csv"), DataFrame)
  transform_to_internal_time(out)
  return out
end

# function generate_reserves(day, input_location, ε=nothing, ρ=nothing)
#   file = joinpath(input_location, g_UC_DATA, "Reserve.csv")
#   if isfile(file)
#     println("Reserve file found, loading reserves...")                            
#     required_reserve = filter_day(day, CSV.read(file, DataFrame))
#   else
#     println("Reserve file not found, generating reserves...")
#     required_reserve = generate_reserves_from_demand(loads_multi_df, gen_variable_multi_df, ε, ρ)
#   end
#   transform_to_internal_time(required_reserve)
#   return required_reserve
# end

function generate_energy_reserve(input_folder)
    out = CSV.read(joinpath(input_folder, g_UC_DATA, "Energy reserve.csv"), DataFrame)
    transform_to_internal_time(out)
    return out
end
# function generate_energy_reserve(day, input_folder, loads_multi_df, gen_variable_multi_df, ε=nothing, ρ=nothing)
#     file = joinpath(input_folder, g_UC_DATA, "Energy reserve.csv")
#     if isfile(file)
#         println("Energy reserve file found, loading reserves...")
#         required_energy_reserve =  filter_day(day, CSV.read(file, DataFrame))
#     else
#         println("Energy reserve file not found, generating reserves...")
#         required_energy_reserve =   generate_energy_reserves(loads_multi_df, gen_variable_multi_df, ε, ρ)
#     end
#      transform_to_internal_time(required_energy_reserve)
#     return required_energy_reserve
# end


# function filter_periods(day, df)
#   # deprecated
#   T_period = (day*24+1):((day+1)*24)
#   # Filtering data with timeseries according to T_period
#   return df[in.(df.hour,Ref(T_period)),:]
# end

function filter_day(day, df)
  if :day in propertynames(df)
    return df[in.(df.day,day),:]
  else
    T_period = ((day-1)*24+1):(((day-1)+1)*24)
    return df[in.(df.hour,Ref(T_period)),:]
  end
end

function transform_to_internal_time(df)
  # This function transforms the time in the dataframe to internal time (1-24)
  # It assumes that the hour is in the range of 1-8760
  for name in names(df)
    if occursin("hour", String(name))
      df[!, name] = mod.(df[!, name] .- 1, 24) .+ 1
    end
  end
  sort!(df, intersect([:r_id, :day, :hour], propertynames(df)))
end 

function filter_demand(expected_load, loads_to_filter, required_reserve)
  # This function will also correctly work if values of load are negative.
  select = :day in propertynames(loads_to_filter) ? [:hour,:day] : [:hour]
  return transform(loads_to_filter, Not(select) .=> (x -> clamp.(x, expected_load.demand .- required_reserve.reserve_down_MW, expected_load.demand .+ required_reserve.reserve_up_MW)) .=> Not(select))
end

function pre_process_generators_data(gen_info,  fuels)
  # Keep columns relevant to our UC model
  columns_to_keep = [:r_id, :full_id, :region, :resource, :cluster, :existing_cap_mw, :min_power, :var_om_cost_per_mwh, :fixed_om_cost_per_mw_per_hour, :start_cost_per_mw, :heat_rate_mmbtu_per_mwh, :fuel, :up_time, :down_time, :ramp_up_percentage, :ramp_dn_percentage, :is_variable]
  select!(gen_info, intersect(columns_to_keep, propertynames(gen_info)))
  # remove generators with no capacity (e.g. new build options that we'd use if this was capacity expansion problem) 
  gen_df = outerjoin(gen_info,  fuels, on = :fuel) # load in fuel costs and add to data frame
  rename!(gen_df, :cost_per_mmbtu => :fuel_cost)   # rename column for fuel cost
  gen_df.fuel_cost[ismissing.(gen_df[:,:fuel_cost])] .= 0

  # create "is_variable" column to indicate if this is a variable generation source (e.g. wind, solar):
  if !(:is_variable in propertynames(gen_df))
    gen_df[!, :is_variable] .= false
    gen_df[in(["onshore_wind_turbine","small_hydroelectric","solar_photovoltaic", "net_generation"]).(gen_df.resource),:is_variable] .= true;
  end

  # create full name of generator (including geographic location and cluster number)
  # for use with variable generation dataframe
  if !(:full_id in propertynames(gen_df))
    gen_df.full_id = gen_df.region .* "_" .* gen_df.resource .* "_" .* string.(gen_df.cluster) .* ".0"
  end
  gen_df.full_id = lowercase.(gen_df.full_id)
  # remove generators with no capacity (e.g. new build options that we'd use if this was capacity expansion problem)
  gen_df = gen_df[gen_df.existing_cap_mw .> 0,:]

  # net generation = -net_load for net_load < 0
  push!(gen_df, last(gen_df))
  last_ = nrow(gen_df)
  for k in names(gen_df)
    gen_df[last_, k] = ifelse(gen_df[last_, k] isa AbstractString, "", 0.0)
  end
  gen_df[last_, :r_id] = maximum(gen_df.r_id) + 1
  gen_df[!, :resource] = String.(gen_df[!, :resource]) # Ensures the column is of type String
  gen_df[last_, :resource] = g_NET_GENERAION_FULL_ID 
  gen_df[last_, :full_id] = g_NET_GENERAION_FULL_ID 
  gen_df[last_, :existing_cap_mw] = 0
  gen_df[last_, :var_om_cost_per_mwh] = 0
  gen_df[last_, :is_variable] = true
  gen_df[last_, :ramp_up_percentage] = 1
  gen_df[last_, :ramp_dn_percentage] = 1
  return identity.(gen_df)
end


function pre_process_storage_data(storage_info)
  df = copy(storage_info)
  if !(:full_id in propertynames(df))
    # create full name of generator (including geographic location and cluster number)
    #  for use with variable generation dataframe
    df.full_id = df.region .* "_" .* df.resource .* "_" .* string.(df.cluster) .* ".0"
  end 
  df.full_id = lowercase.(df.full_id)
  return df
end

function pre_process_storage_data_old(storage_info, day, storage_final_energy)
  df = copy(storage_info)
  if !(:full_id in propertynames(df))
    # create full name of generator (including geographic location and cluster number)
    #  for use with variable generation dataframe
    df.full_id = df.region .* "_" .* df.resource .* "_" .* string.(df.cluster) .* ".0"
  end 
  df.full_id = lowercase.(df.full_id)
  if !isnothing(storage_final_energy) && day in storage_final_energy.day
    SOE_last = storage_final_energy[storage_final_energy.day .== day,[:r_id, :final_energy_proportion]]
    df = select(df, Not(intersect(propertynames(df), [:final_energy_proportion]))) # discard :final_energy_proportion if present
    df = leftjoin(df, SOE_last, on = :r_id)
  end
  return df
end

function pre_process_load_gen_variable(gen_df, loads_df, gen_variable)
  # Used for UC and EC. Tranfers negative demand to generation
  # includes net generation asset in gen_df with installed capacity = -min(loads_df.demand) 
  filter = loads_df.demand.<0
  if !any(filter)
    net_generation = copy(loads_df)
    net_generation.generation .= 0
    installed_capacity = 0
    net_generation.cf .= 0
  else
    net_generation = loads_df[filter,:]
    net_generation.generation = - net_generation.demand
    loads_df[filter,:demand].=0
    installed_capacity = maximum(net_generation.generation)
    net_generation.cf = net_generation.generation./installed_capacity
  end
  net_generation.full_id .= g_NET_GENERAION_FULL_ID

  gen_df = copy(gen_df)
  gen_df[gen_df.full_id .== g_NET_GENERAION_FULL_ID, :existing_cap_mw] .= installed_capacity # Assumes that the element is already in the df

  gen_variable[gen_variable[!, :full_id] .== g_NET_GENERAION_FULL_ID,:cf] .= 0 # values reset to zero for re-iterations on the ED
  gen_variable[gen_variable[!, :full_id] .== g_NET_GENERAION_FULL_ID,:existing_cap_mw] .= installed_capacity # values reset to zero for re-iterations on the ED
  gen_variable = leftjoin(gen_variable, select(net_generation, Not([:demand,:generation])), on = [:hour, :full_id], makeunique = true) # We add :cf and :existing_cap_mw to gen_variable only on the hour where net_generation>0. # Since this is not happening at each hour, we have to create two columns cd_1 and cf_2
  join_on = intersect([:day, :hour], propertynames(gen_variable))
  gen_variable = select(gen_variable, union(join_on, [:full_id, :r_id, :existing_cap_mw]), [:cf_1, :cf] =>ByRow(coalesce) => [:cf]) # We then select columns :cf_1, then :cf and rename them to :cf
  # gen_variable[gen_variable.full_id.== g_NET_GENERAION_FULL_ID, :existing_cap_mw] .= installed_capacity
  return gen_df, loads_df, sort(gen_variable,union([:r_id], join_on))
end


function pre_process_scenarios_demand_gen_variable(gen_df, scenarios_demand, gen_variable)
  select_ = :day in propertynames(scenarios_demand) ? [:hour,:day] : [:hour]
  net_generation =  copy(scenarios_demand)
  net_generation = transform(net_generation, Not(select_) .=> ByRow(x -> max.(-x,0)), renamecols=false)
  scenarios_demand = transform(scenarios_demand, Not(select_) .=> ByRow(x -> max.(x,0)), renamecols=false) # We set the demand to 0 if negative  


  # Exclude :hour and :day columns to get the maximum value across all other columns
  installed_capacity = maximum(reduce(vcat, eachcol(net_generation[!, Not([:hour, :day])]))) #  max across hours and scenarios
  # net_generation[!, Not([:hour, :day])]  = net_generation[!, Not([:hour, :day])] ./ installed_capacity # cf = generation / installed_capacity  
  net_generation = stack(net_generation, Not([:hour, :day]), variable_name=:scenario, value_name=:cf)
  net_generation.cf .= installed_capacity != 0 ? net_generation.cf ./ installed_capacity : 0
  net_generation.full_id .= g_NET_GENERAION_FULL_ID
  net_generation.existing_cap_mw .= installed_capacity
  net_generation.r_id .= gen_df[gen_df.full_id.== g_NET_GENERAION_FULL_ID,:r_id]
  # Replicate gen_variable for each scenario and join to net_generation
  gen_variable = gen_variable[gen_variable.full_id .!= g_NET_GENERAION_FULL_ID,:] 
  gen_variable = filter(row -> row.hour in net_generation.hour, gen_variable)
  scenarios_list = unique(net_generation.scenario)
  gen_variable_expanded = vcat([transform(gen_variable, :full_id => (_ -> s) => :scenario) for s in scenarios_list]...)
  gen_variable_expanded.scenario = convert.(eltype(net_generation.scenario), gen_variable_expanded.scenario)
  gen_variable = vcat(gen_variable_expanded, net_generation)

  gen_df[gen_df.full_id .== g_NET_GENERAION_FULL_ID, :existing_cap_mw] .= installed_capacity 
  
  # gen_variable = leftjoin(gen_variable_expanded, net_generation, on=[:day, :hour, :full_id, :scenario], makeunique=true)
  # gen_variable = select(gen_variable, Not(:cf_1), :cf => ByRow(coalesce) => :cf)
  return gen_df, scenarios_demand, gen_variable
end



function pre_process_gen_variable(gen_df, gen_variable_info)
  # It sets g_NET_GENERAION_FULL_ID's cf to zero and adds existing_cap_mw based on gen_df. Needed for UC.
  gen_variable_info[!,g_NET_GENERAION_FULL_ID] .= 0 # net generation = -net_load for net_load < 0
  select_ = :day in propertynames(gen_variable_info) ? [:hour,:day] : [:hour]
  aux = stack(gen_variable_info, Not(select_), variable_name=:full_id, value_name=:cf)
  return innerjoin(aux,
    gen_df[gen_df.is_variable .== 1,[:r_id, :full_id, :existing_cap_mw]],
    on = :full_id)
end

function read_random_demand(input_location = g_DEFAULT_LOCATION)
  return CSV.read(joinpath(input_location, "ed", "random_demand.csv"), DataFrame)
end

function read_demand_scenarios(input_location)
  return CSV.read(joinpath(input_location, g_UC_DATA, "scenarios", "scenarios_demand.csv"), DataFrame)
end

function read_probability_scenarios(input_location)
  return CSV.read(joinpath(input_location, g_UC_DATA, "scenarios", "scenarios_probability.csv"), DataFrame)
end

function generate_scenarios_data(input_location = g_DEFAULT_LOCATION)
  return read_demand_scenarios(input_location),read_probability_scenarios(input_location)
end

function generate_scenarios_data_deprecated(day, input_location = g_DEFAULT_LOCATION)
  return (demand = filter_day(day, read_demand_scenarios(input_location)), probability = read_probability_scenarios(input_location))
end

function read_reserve(input_location = g_DEFAULT_LOCATION)
  return CSV.read(joinpath(input_location, g_UC_DATA, "Reserve.csv"), DataFrame)
end


function read_parquet_and_convert(file)
  columns_to_symbol = [:configuration, :iteration]
  println(file)
  out = DataFrame(Parquet2.Dataset(file); copycols=false)
  for k in intersect(columns_to_symbol, propertynames(out))
    out[!, k] = Symbol.(out[!, k])
  end
  return out
end

# --- end pre_processing ---


function generate_configuration(μ_up, μ_dn, storage_df; reserve=nothing, energy_reserve=nothing)
  out = Dict(
    :ramp_constraints => true,
    :storage => storage_df,
    :enriched_solution => true,
    :storage_envelopes => true,
    :μ_up => μ_up,
    :μ_dn => μ_dn)
  if !isnothing(energy_reserve)
    out[:energy_reserve] = energy_reserve
  else 
    out[:reserve] = reserve
  end
  return out
end

function generate_reserves_old(loads, gen_variable, margin_percentage, baseload = 0)
  # deprecated
  filter = gen_variable[!,:full_id] .== g_NET_GENERAION_FULL_ID
  net_gen = gen_variable[filter,:cf] .* gen_variable[filter,:existing_cap_mw]
  required_reserve = DataFrame(
    hour = loads[!,:hour],
    reserve_up_MW = baseload .+ (loads[!,:demand] .+ net_gen).*margin_percentage,
    reserve_down_MW = (loads[!,:demand] .+ net_gen).*margin_percentage)
  required_reserve = (required_reserve.>0).*required_reserve .- (required_reserve.<0).*required_reserve # negative to positive values
  return required_reserve
end

function generate_reserves_from_demand(loads, gen_variable, ε, ρ; margin=0.1)
  # deprecated
  filter = gen_variable[!,:full_id] .== g_NET_GENERAION_FULL_ID
  net_gen = gen_variable[filter,:cf] .* gen_variable[filter,:existing_cap_mw]
  p = 1-ε # 0.975
  μ = (loads[!,:demand] .+ net_gen)
  var =  get_var(μ , ρ, p, margin)
  σ = vec(sqrt.(var))
  normals = Normal.(0, σ)
  return DataFrame(
    hour = loads[!,:hour],
    reserve_up_MW = quantile.(normals, p),
    reserve_down_MW = -cquantile.(normals, p))
end

function generate_energy_reserves_from_demand(loads, gen_variable, ε, ρ; margin=0.1)
  # deprecated
  # Assumes that X[t] t = [1...24] are independent N(0,σ[t])
  # therefore Z[i,t] = sum_{τ=i}^t X[τ] is N(0,σ_Z[i,t]) with σ_Z[i,t] = (sum_{τ=i}^t σ[τ]^2)^1/2
  filter = gen_variable[!,:full_id] .== g_NET_GENERAION_FULL_ID
  net_gen = gen_variable[filter,:cf] .* gen_variable[filter,:existing_cap_mw]
  p = 1-ε
  # σ = quantile(Normal(),p)
  μ = (loads[!,:demand] .+ net_gen)
  var =  get_var(μ , ρ, p, margin) # calculates var[t] for each autocorroleated X[t] 
  σ = zeros(size(var,1), size(var,1))
  t_H = diagm(loads[!,:hour])
  i_H = diagm(loads[!,:hour])
  for i in 1:size(σ,1), j in i:size(σ,2)
    σ[i,j] = sqrt(sum((var)[i:j])) # σ_Z[t] = (sum_{τ=i}^t σ[τ]^2)^1/2 with var[t] = σ[t]^2
    t_H[i,j] = t_H[i,i] + j-i
    i_H[i,j] = i_H[i,i]
  end
  normals = Normal.(0, σ)
  r_up = quantile.(normals, p)
  r_down = -cquantile.(normals, p)
  return DataFrame(
    i_hour = vcat([i_H[i,i:end] for i in 1:size(i_H,1)]...),
    t_hour = vcat([t_H[i,i:end] for i in 1:size(t_H,1)]...),
    reserve_up_MW =  vcat([r_up[i,i:end] for i in 1:size(r_up,1)]...),
    reserve_down_MW = vcat([r_down[i,i:end] for i in 1:size(r_down,1)]...)
  )
end


function generate_energy_reserves_deprecated(required_reserve)
  # deprecated
  required_energy_reserve = [(row_1.hour, row_2.hour, row_1.reserve_up_MW*(row_1.hour == row_2.hour), row_1.reserve_down_MW*(row_1.hour == row_2.hour)) for row_1 in eachrow(required_reserve), row_2 in eachrow(required_reserve) if row_1.hour <= row_2.hour]
  required_energy_reserve = DataFrame(required_energy_reserve)
  required_energy_reserve = rename(required_energy_reserve, :1 => :i_hour, :2 => :t_hour, :3 => :reserve_up_MW, :4 => :reserve_down_MW,)
  return required_energy_reserve
end

function generate_energy_reserves_cumulative(required_reserve)
  # deprecated
  required_energy_reserve_cumulated = [(row_1.hour, row_2.hour, sum(required_reserve[(required_reserve.hour .>= row_1.hour).&(required_reserve.hour .<= row_2.hour),:reserve_up_MW]), sum(required_reserve[(required_reserve.hour .>= row_1.hour).&(required_reserve.hour .<= row_2.hour),:reserve_down_MW])) for row_1 in eachrow(required_reserve), row_2 in eachrow(required_reserve) if row_1.hour <= row_2.hour]
  required_energy_reserve_cumulated = DataFrame(required_energy_reserve_cumulated)
  required_energy_reserve_cumulated = rename(required_energy_reserve_cumulated, :1 => :i_hour, :2 => :t_hour, :3 => :reserve_up_MW, :4 => :reserve_down_MW,)
  return required_energy_reserve_cumulated
end