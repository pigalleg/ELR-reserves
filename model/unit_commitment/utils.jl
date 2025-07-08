include("./config.jl")

function update_parameter_value(model, key, value)
  # Updates the value of a parameter in the model
  println("$key")
  for idx in eachindex(model[key])
    set_parameter_value(model[key][idx], value[CartesianIndex(idx)]) # when model[key] is DenseAxisArray, then idx is cartesian but if it is SparseAxisArray, then idx is a tuple 
  end
  end

function remove_variable_constraint(model, key, delete_ = true)
  # Applies for constraints and variables
  println("Removing $key...")
  if !haskey(model, key)
      println("variable not in model")
      return
  end
  if delete_ delete.(model, model[key]) end # Constraints must be deleted also
  unregister(model, key)
end


function create_generators_sets(gen_df)
  # Thermal resources for which unit commitment constraints apply
  G_thermal = gen_df[gen_df[!,:up_time] .> 0,:r_id] 
      
  # Non-thermal resources for which unit commitment constraints do NOT apply 
  G_nonthermal = gen_df[gen_df[!,:up_time] .== 0,:r_id]
  
  # Variable renewable resources
  G_var = gen_df[gen_df[!,:is_variable] .== 1,:r_id]
  
  # Non-variable (dispatchable) resources
  G_nonvar = gen_df[gen_df[!,:is_variable] .== 0,:r_id]
  
  # Non-variable and non-thermal resources
  G_nt_nonvar = intersect(G_nonvar, G_nonthermal)
  # Note that G_nt_var = G_var

  # Set of all generators (above are all subsets of this)~
  G = gen_df.r_id

  return G, G_thermal, G_nonthermal, G_var, G_nonvar, G_nt_nonvar
end

function create_time_sets()
  return collect(1:g_HORIZON_LENGTH), collect(1:g_HORIZON_LENGTH-1)
end

function get_sets(gen_df, probability = nothing) #stochastic
  G, G_thermal, G_nonthermal, G_var, G_nonvar, G_nt_nonvar = create_generators_sets(gen_df)
  T, T_red = create_time_sets()
  out = (
      G = G,
      G_thermal = G_thermal,
      G_nonthermal = G_nonthermal,
      G_var = G_var,
      G_nonvar = G_nonvar,
      G_nt_nonvar = G_nt_nonvar,
      T = T,
      T_red = T_red
    )
  if !isnothing(probability)
    return merge(out, (Σ = create_scenarios_sets(probability), ))
  else
    return out
  end
end

function create_storage_sets(storage)
  return storage.r_id
end

function create_scenarios_sets(scenarios_probability)
    return scenarios_probability.scenario
end

function convert_to_indexed_vector(value, T)
  if value isa Number
      return Dict(T .=> fill(value, length(T)))
  else
      return Dict(T .=> value)
  end
end

function convert_to_vector(value)
  return fill(value, g_HORIZON_LENGTH)
end