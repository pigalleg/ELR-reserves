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

2. Install DVC with Google Drive support. The DVC documentation recommends using an isolated Python environment (for example, a virtual environment or `pipx`). With your chosen environment active, run:
    ```sh
    python -m pip install "dvc[gdrive]"
    ```

3. Configure the Google Drive credentials. The shared `gdrive` remote is already defined in `.dvc/config`; ask the repository maintainer for the confidential OAuth client ID and client secret, then store them only in your local DVC configuration:
    ```sh
    dvc remote modify --local gdrive gdrive_client_id "<client-id>"
    dvc remote modify --local gdrive gdrive_client_secret "<client-secret>"
    ```

    The `--local` option writes these values to `.dvc/config.local`, which is ignored by Git. **The OAuth client ID and client secret can be shared with authorized collaborators upon request to the repository maintainer.** These values identify the project's Google OAuth application; they are not your personal Google credentials.

4. Download the DVC-managed data:
    ```sh
    dvc pull
    ```

    On first use, DVC starts a Google authorization flow. Sign in with a Google account that has access to the configured Drive folder and grant the requested permissions. DVC caches the resulting personal authorization token outside the repository; do not share this token. Each collaborator must authorize their own account separately.

    See the [DVC Google Drive remote documentation](https://doc.dvc.org/user-guide/data-management/remote-storage/google-drive) for credential setup details, cache locations, reauthorization, service accounts, and troubleshooting.

5. Open Julia and activate the environment:
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

Run commands from the repository root in the activated Julia environment. The maintained workflow solves one deterministic unit commitment (UC) for each day and reserve configuration, then runs economic dispatch (ED) for scenarios from `ed/random_demand.csv`:

```julia
include("./main.jl")
```

An input folder must contain the model data under `uc/` and the Monte Carlo demand scenarios at `ed/random_demand.csv`. The examples below use the DVC-managed `input/RTS-GMLC_v2.4.2` dataset.

### Configuration-file runs

Configuration CSV files are read from `<input_folder>/uc/`. Pass `days` to select a subset of the days in the file, or omit it to run every listed day.

Envelope (classic reserve):

```julia
generate_ed_solutions(
    days = collect(1:7),
    day_µ_configurations_file = "configuration_envelopes_e_reserve_mu_v3",
    input_folder = "./input/RTS-GMLC_v2.4.2",
    output_folder = "./output/RTS-GMLC_envelope",
    energy_reserve = false,
)
```

Energy-reserve (energy envelope):

```julia
generate_ed_solutions(
    days = collect(1:7),
    day_µ_configurations_file = "configuration_e_reserves",
    input_folder = "./input/RTS-GMLC_v2.4.2",
    output_folder = "./output/RTS-GMLC_energy_reserve",
    energy_reserve = true,
)
```

Do not include the `.csv` suffix in `day_µ_configurations_file`.

### Explicit day and μ runs

Instead of a CSV, pass equal-length `days` and `μs` vectors. Each pair is one row; repeat a day to evaluate multiple μ values for that day. For example, this runs μ = 0 and μ = 1 on days 1 and 2:

```julia
generate_ed_solutions(
    days = [1, 1, 2, 2],
    μs = [0.0, 1.0, 0.0, 1.0],
    input_folder = "./input/RTS-GMLC_v2.4.2",
    output_folder = "./output/RTS-GMLC_selected_mu",
    energy_reserve = false,
)
```

For the standard energy-reserve formulation, use μ = 1:

```julia
generate_ed_solutions(
    days = collect(1:7),
    μs = ones(7),
    input_folder = "./input/RTS-GMLC_v2.4.2",
    output_folder = "./output/RTS-GMLC_energy_reserve",
    energy_reserve = true,
)
```

### Outputs and common options

By default, `write = true` saves feasible `s_uc_*.parquet` and `s_ed_*.parquet` files under `<output_folder>/n_<day>/`. Infeasible scalar results are written under `<output_folder>/infeasible/n_<day>/`. After all requested days finish, `write_post_processing_files = true` (the default) builds aggregate KPI parquet files in the output folder. To run without writing files, set both `write = false` and `write_post_processing_files = false`.

The most commonly adjusted keyword arguments are:

- `max_iterations`: Maximum number of ED scenario columns to run from `ed/random_demand.csv` for each UC solution (default: `1`).
- `mip_gap`: Solver optimality gap (default: `1e-4`).
- `thermal_reserve`: Allow thermal generators to provide reserve (default: `true`).
- `storage_reserve_repartition`: Storage share of reserve; `-1` disables repartitioning, `0` assigns none to storage, and a positive value sets the storage share (default: `-1`).
- `bidirectional_storage_reserve`: Allow storage to provide reserve while charging or discharging (default: `true`).
- `constrain_SOE_by_envelopes`: Enforce the UC state-of-energy envelopes in ED (default: `false`).
- `constrain_redispatch_by_energy`: Apply energy limits to ED redispatch (default: `false`).
- `variables_to_constrain`: UC variable families used to restrict ED (default: `[:GEN, :CH, :DIS]`).
- `VLOL`, `VLGEN`, `VRESERVE`, `VSRESUP`, `VSRESDN`, `VSSOEFinal`: Objective and slack penalty coefficients.
- `set_storage_inflows`: Include storage inflows when available (default: `true`).
- `write`: Persist per-day solutions (default: `true`).
- `write_post_processing_files`: Generate aggregate KPI files after a run (default: `true`).

To apply the same run settings to several datasets, pass `(input_folder, output_folder)` pairs through `folders` instead of the two individual folder keywords:

```julia
generate_ed_solutions(
    days = [1],
    μs = [1.0],
    folders = [
        ("./input/RTS-GMLC_v2.4", "./output/RTS-GMLC_v2.4"),
        ("./input/RTS-GMLC_v2.4.2", "./output/RTS-GMLC_v2.4.2"),
    ],
)
```

### Stochastic unit commitment

`generate_suc_solutions` is currently unmaintained and its wrapper is not runnable. Use `generate_ed_solutions` for the maintained UC plus Monte Carlo ED workflow.

## Batch execution

Two helper scripts are available under `./scripts` to run batches from the command line:

- [scripts/run_batches_envelope.sh](scripts/run_batches_envelope.sh): runs envelope (classic reserve) batches.
- [scripts/run_batches_e_reserve.sh](scripts/run_batches_e_reserve.sh): runs energy-reserve batches.

Usage (make sure they are executable, e.g., `chmod +x scripts/run_batches_envelope.sh scripts/run_batches_e_reserve.sh`):

The scripts split the requested day range into up to `num_instances` batches and launch each batch concurrently in a separate background Julia process. They wait for all processes to finish before returning.

```
# Arguments: <initial_day> <final_day> <num_instances> <input_folder> <output_folder>

# Envelope (classic reserve) batch
./scripts/run_batches_envelope.sh 1 365 8 RTS-GMLC_v2.4.2 RTS-GMLC_v24.1su

# Energy-reserve batch
./scripts/run_batches_e_reserve.sh 1 365 8 RTS-GMLC_v2.4.2 RTS-GMLC_v24.1su
```

The scripts internally call `generate_ed_solutions` with the appropriate configuration files:
- Envelope: `day_µ_configurations_file = "configuration_envelopes_e_reserve_mu_v3"`, `energy_reserve = false`
- Energy-reserve: `day_µ_configurations_file = "configuration_e_reserves"`, `energy_reserve = true`

You can edit the scripts to adjust days, μ configurations, input/output folders, or flags before running.

## Quick start: run envelope vs. energy-reserve

Envelope (default):

```
julia --project=. -e 'include("main.jl"); generate_ed_solutions(days=[1], μs=[1.0], input_folder="./input/RTS-GMLC_v2.4.2", output_folder="./output/RTS-GMLC_envelope", energy_reserve=false)'
```

Energy-reserve:

```
julia --project=. -e 'include("main.jl"); generate_ed_solutions(days=[1], μs=[1.0], input_folder="./input/RTS-GMLC_v2.4.2", output_folder="./output/RTS-GMLC_energy_reserve", energy_reserve=true)'
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