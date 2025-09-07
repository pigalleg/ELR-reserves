using JuMP: @variable
using JuMP.Containers: DenseAxisArray, SparseAxisArray
include("./config.jl")

function is_non_feasible(model)
  # We consider infeasible only when terminaton_status = infeasible.
  # For instance, for time_limit reached, the model is not infeasible, nor within mip_gap but still has a solution, we therefore try to recover it
  return (JuMP.termination_status(model) == MOI.INFEASIBLE)
end


function copy_initialize(model_)
  model = JuMP.copy(model_)
  set_solver_attributes(model)
  return model
end

function set_solver_attributes(model, mip_gap = nothing)
    set_optimizer(model, Gurobi.Optimizer)
    if !isnothing(mip_gap)
        set_optimizer_attribute(model, "MIPGap", mip_gap)
        @variable(model, MIPGap in Parameter(mip_gap))
    else
        set_optimizer_attribute(model, "MIPGap", parameter_value(model[:MIPGap]))
    end
    # Logging.disable_logging(Logging.Warn)
    # set_optimizer_attribute(model, "LogFile", "./output/log_file.txt")
    # set_optimizer_attribute(model, "mip_rel_gap", mip_gap)
    set_optimizer_attribute(model, "TimeLimit", 600)
    set_optimizer_attribute(model, "OutputFlag", 0)
    # set_optimizer_attribute(model, "msg_lev", GLPK.GLP_MSG_ALL)  # Enable logging
    # set_optimizer_attribute(model, "log_file", "log.txt")   # Save log to file
    # set_optimizer_attribute(model, "MIPFocus", 2)
    # set_optimizer_attribute(model, "Cuts", 2)
    # set_optimizer_attribute(model, "StartNodeLimit", 0)
    # set_optimizer_attribute(model, "Heuristics", 0.3)
    # set_optimizer_attribute(model, "NumericFocus", 2)         # moderate numeric focus
    # set_optimizer_attribute(model, "ScaleFlag", 1)            # stronger internal scaling
    # set_optimizer_attribute(model, "Method", 2)               # barrier method for root
    # set_optimizer_attribute(model, "BarHomogeneous", 1)       # homogeneous self-dual barrier
    if !haskey(model, :FeasibilityTol)
        @variable(model, FeasibilityTol in Parameter(get_optimizer_attribute(model, "FeasibilityTol")))
    end
end

function convert_to_matrix(df, row_key, column_key, value_key)
    return  Matrix(unstack(df, row_key, column_key, value_key)[:,Not(row_key)])
end

function update_parameter_value(model, key, value::Union{Matrix, Vector, DenseAxisArray, SparseAxisArray})
  # Updates the value of a parameter in the model
  # model[key]: DenseAxisArray => value: vector or DenseAxisArray
  # model[key]: SparseAxisArray => value: Matrix or SparseAxisArray
  println("$key")
  # when model[key] is DenseAxisArray, then idx is cartesian but if it is SparseAxisArray, then idx is a tuple. We need to convert to cartesian if Matrix
  convert_index(idx) = (value isa Matrix) ? CartesianIndex(idx) : idx 
  for idx in eachindex(model[key])
    set_parameter_value(model[key][idx], value[convert_index(idx)]) 
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
  return collect(1:g_horizon_length), collect(1:g_horizon_length-1)
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
  return fill(value, g_horizon_length)
end