g_horizon_length = 24

# read data
g_cap_ed_load_to_reserves = false

# Construct deterministic unit commitment
g_reserve = false
g_energy_reserve = false
g_storage_envelopes = true
g_storage_link_constraint = false
g_storage_reserve_repartition = -1 # -1 means no repartitioning, 0 means no reserve for storage, and any other positive number is the percentage of the reserve that should be allocated to storage
g_VRESERVE = 1e-6
g_VSRESUP = 250 # <- 1e+4
g_VRESDN = 250 # <- 30
g_bidirectional_storage_reserve = true # update_dispatch_restrictions
g_thermal_reserve = true
g_naive_envelopes = false

# construct_unit_commitment & construct_economic_dispatch
g_storage = nothing
g_ramp_constraints = true
g_mip_gap = 1e-4
g_expected_min_SOE = false
g_VLOL = 1e4 # 
g_VLGEN = 30 # <- 0
g_set_storage_inflows = true # If true, storage inflows are considered in the model

# construct_economic_dispatch
g_constrain_SOE_by_envelopes = false
g_constrain_redispatch_by_energy = false
g_VSSOEFinal = 1e3 # <=VLOL*round_trip_efficiency

# update_dispatch_restrictions
g_constrain_redispatch = true
g_remove_variables_from_objective = false
 # If true, the reserve variables are constrained by the energy reserve variables

# launch_monte_carlo_get_solution
g_max_iterations = 1

# get_variables_to_constrain
g_variables_to_constrain = [:GEN] # Variables to constrain in the economic dispatch model

# get_model_solution
g_dual_variables = true
g_enriched_solution = true # If true, the solution is enriched with additional information such as dual variables and storage state of energy   