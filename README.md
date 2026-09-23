# Comparative analysis of reserve formulations: Leveraging flexibility from energy-limited resources

This repository contains the code accompanying the following publication:

> **Comparative analysis of reserve formulations: Leveraging flexibility from energy-limited resources**  
> **Pablo Gallegos, Elina Spyrou, and Enzo Sauma**  
> *Electric Power Systems Research*, Volume 263, 2027, Article 113663.  
> DOI: https://doi.org/10.1016/j.epsr.2026.113663

## Installation

To get started with this project, follow the steps below:

1. Clone the repository:
    ```sh
    git clone https://github.com/pigalleg/energy_reserve.git
    cd energy_reserve
    ```

2. Open Julia and activate the environment:
    ```julia
    using Pkg
    Pkg.activate(".")
    Pkg.instantiate()
    ```

## Package activation 

To activate the Julia package before each run, you can use one of the following methods:

1. Using the Julia REPL:
    ```julia
    using Pkg
    Pkg.activate(".")
    ```

2. Using the command line:
    ```sh
    julia --project=.
    ```

## Simulation framework run

To run the complete simulation framework i.e., a Unit Committment followed by several Economic Dispatches (Monte Carlo), first include the main script in the Julia REPL:
```julia
include("./main.jl")
```

Each simulation is launched individually for a given set of days.

### Economic Dispatch (generate_ed_solutions)

**Envelope (classic reserve):**

```
generate_ed_solutions(
    days = [1,2,3,4,5,6,7],
    μs = [0, 0.2, 0.3, 0.4, 0.6, 0.8, 0.9, 1],
    input_folder = "./input/simulation_input",
    output_folder = "./output/simulation_output",
    energy_reserve = false  # default
)
```

You can also supply `day_µ_configurations_file = "configuration_envelopes_e_reserve_mu"` instead of explicitly passing `days` and `μs`; when provided, `days` becomes optional and acts only as a filter on the days listed in that file.

**Energy-reserve (energy envelope):**

```
generate_ed_solutions(
    days = [1,2,3,4,5,6,7],
    μs = [1,1,1,1,1,1,1],
    input_folder = "./input/simulation_input",
    output_folder = "./output/simulation_output",
    energy_reserve = true
)
```

You can also supply `day_µ_configurations_file = "configuration_e_reserves"` instead of explicitly passing `days` and `μs`; when provided, `days` is optional and will filter the days listed in that configuration file.

Notes:
- For energy-reserve, use μ = 1 (standard formulation). Additional μ values will scale the envelopes if provided.
- Set `write=true` to persist results.

Common options:
- `VRESERVE` (MWh/$): Value of committed reserve in the UC.
- `VLGEN` (MWh/$): Value of curtailed generation in the ED (renewables and committed gen).
- `thermal_reserve` (Bool): Allow thermal unit reserve provision in UC/ED.
- `constrain_SOE_by_envelopes` (Bool): Enforce SOE envelopes during ED re-dispatch.
- `mip_gap` (Float): MILP gap tolerance.
- `ρ`, `ε` (Float): Model parameters (tune as needed).
- `bidirectional_storage_reserve`, `variables_to_constrain`, `storage_reserve_repartition`: advanced options.
- `write` (Bool): Save simulation outputs.

3.- Stochastic model

```
generate_suc_solutions(days = [1,2,3,4,5,6,7], input_folder = "./input/SDG&E_ρ_0.8", output_folder = "./output/simulation_output", expected_min_SOE = false)
```
If ``expected_min_SOE = true``, then the expected end-of-horizon SOE must be higuer or equal to the 'final_energy_proportion' parameter found in the 'Storage_data.csv' input file. The expected end-of-horizon SOE is set to the initial stored energy otherwise.

Optional arguments include: 
- VLGEN [MWh/$] value of curtailed generation in the SUC problem. 
- write [BOOLEAN]: whether to save simulation results.
- ...

> Note: The stochastic model (generate_suc_solutions) is currently not maintained/working.

## Batch execution

Two helper scripts are available under `./scripts` to run batches from the command line:

- [scripts/run_batches_envelope.sh](scripts/run_batches_envelope.sh): runs envelope (classic reserve) batches.
- [scripts/run_batches_e_reserve.sh](scripts/run_batches_e_reserve.sh): runs energy-reserve batches.

Usage (make sure they are executable, e.g., `chmod +x scripts/run_batches_envelope.sh scripts/run_batches_e_reserve.sh`):

```
# Arguments: <initial_day> <final_day> <num_instances> <input_folder> <output_folder>

# Envelope (classic reserve) batch
./scripts/run_batches_envelope.sh 1 365 8 RTS-GMLC_v2.4.2 RTS-GMLC_v24.1su

# Energy-reserve batch
./scripts/run_batches_e_reserve.sh 1 365 8 RTS-GMLC_v2.4.2 RTS-GMLC_v24.1su
```

The scripts internally call `generate_ed_solutions` with the appropriate configuration files:
- Envelope: `day_µ_configurations_file = "configuration_envelopes_e_reserve_mu"`, `energy_reserve = false`
- Energy-reserve: `day_µ_configurations_file = "configuration_e_reserves"`, `energy_reserve = true`

You can edit the scripts to adjust days, μ configurations, input/output folders, or flags before running.

## Quick start: run envelope vs. energy-reserve

Envelope (default):

```
julia --project=. -e 'include("main.jl"); generate_ed_solutions(days=[1], μs=[1], input_folder="./input/SDG&E_ρ_0.8", output_folder="./output/simulation_output", energy_reserve=false, write=true)'
```

Energy-reserve:

```
julia --project=. -e 'include("main.jl"); generate_ed_solutions(days=[1], μs=[1], input_folder="./input/SDG&E_ρ_0.8", output_folder="./output/simulation_output", energy_reserve=true, write=true)'
```

Adjust `days`, `μs`, and folders as needed. Set `write=true` to persist results to `./output`.

## Model parameter categorization

Parameters are organized across different config files and the main entry point. Here's where each parameter belongs:

### Unit Commitment only ([model/unit_commitment/config.jl](model/unit_commitment/config.jl))

These parameters configure the unit commitment problem:
- `g_horizon_length = 24`: Planning horizon in hours
- `g_cap_ed_load_to_reserves = false`: Cap ED load to reserves (Bool)
- `g_reserve = false`: Enable reserve constraints in UC (Bool)
- `g_energy_reserve = false`: Enable energy reserve constraints (Bool)
- `g_storage_envelopes = true`: Use storage SOE envelopes (Bool)
- `g_storage_link_constraint = false`: Link storage constraints (Bool)
- `g_storage_reserve_repartition = -1`: Allocate reserve percentage to storage (Int: -1=no, 0=none, >0=%)
- `g_VRESERVE = 1e-6`: Reserve valuation weight
- `g_VSRESUP = 250`: Storage reserve up cost
- `g_VRESDN = 250`: Storage reserve down cost
- `g_bidirectional_storage_reserve = true`: Allow bidirectional reserve (Bool)
- `g_thermal_reserve = true`: Allow thermal units to provide reserve (Bool)
- `g_naive_envelopes = false`: Use naive envelope formulation (Bool)

### Both UC and ED ([model/unit_commitment/config.jl](model/unit_commitment/config.jl))

These parameters affect both unit commitment and economic dispatch:
- `g_storage = nothing`: Storage data structure to use
- `g_ramp_constraints = true`: Enforce unit ramp limits (Bool)
- `g_mip_gap = 1e-4`: MILP solver optimality gap tolerance
- `g_expected_min_SOE = false`: Enforce expected minimum SOE at horizon end (Bool)
- `g_VLOL = 1e4`: Loss of load penalty ($/MWh)
- `g_VLGEN = 30`: Loss of generation penalty ($/MWh)
- `g_set_storage_inflows = true`: Include storage inflows (Bool)

### Economic Dispatch only ([model/economic_dispatch.jl](model/economic_dispatch.jl))

These parameters configure the economic dispatch problem:
- `g_constrain_SOE_by_envelopes = false`: Enforce SOE within UC envelopes (Bool)
- `g_constrain_redispatch_by_energy = false`: Constrain ED redispatch by energy limits (Bool)
- `g_VSSOEFinal = 1e3`: Penalty for violating end-of-horizon SOE targets
- `g_constrain_redispatch = true`: Allow unit redispatch from UC (Bool)
- `g_remove_variables_from_objective = false`: Remove reserve vars from objective (Bool)
- `g_variables_to_constrain = [:GEN,:CH,:DIS]`: Array of variable types to constrain
- `g_max_iterations = 1`: Number of Monte Carlo iterations (ED runs per UC solution)

### Solution output options ([model/unit_commitment/config.jl](model/unit_commitment/config.jl))

Configuration of solution output and enrichment:
- `g_dual_variables = true`: Include dual variables in solution (Bool)
- `g_enriched_solution = true`: Add auxiliary variables and state (Bool)

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.