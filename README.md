# Energy Reserve

This repository contains the code for the Energy Reserve project.

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

To run the complete simulation framework i.e, a Unit Committment followed by several Economic Dispatches (Monte Carlo), first include the main script in the Julia REPL:
```julia
include("./main.jl")
```

Each simulation is launched individually for a given set of days.

1. Classic reserve with 'envelope' constraints and a set of multipliers μ:

```
generate_ed_solutions(days = [1,2,3,4,5,6,7], μs=[0, 0.2, 0.3, 0.4, 0.6, 0.8, 0.9, 1], input_folder = "./input/SDG&E_ρ_0.8", output_folder = "./output/simulation_output")
```

2. Energy reserve with 'energy envelope' constraints:

```
generate_ed_solutions(days = [1,2,3,4,5,6,7], μs=[1], input_folder = "./input/SDG&E_ρ_0.8", output_folder = "./output/simulation_output", energy_reserve = true)
```
We note that 'energy envelopes' include a multipliers μ that needs to be set to 1 to get the standard formulation. 

Optional arguments include: 
- VRESERVE [MWh/$] value of commited reserve in the UC problem.
- VLGEN [MWh/$] value of curtailed generation in the ED problem. Applies to renewable generation, and commited generation from the UC problem.
- thermal_reserve [BOOLEAN]: Thermal unit reserve provision in the UC and ED problems.
- constrain_SOE_by_envelopes [BOOLEAN]: Whether re-dispatch of stoarge units must respect SOE envelopes in ED problem.
- bidirectional_storage_reserve #TODO
- variables_to_constrain #TODO
- storage_reserve_repartition #TODO
- mip_gap #TODO
- ε #TODO
- ρ #TODO
- write [BOOLEAN]: whether to save simulation results.

3.- Stochastic model

```
generate_suc_solutions(days = [1,2,3,4,5,6,7], input_folder = "./input/SDG&E_ρ_0.8", output_folder = "./output/simulation_output", expected_min_SOE = false)
```
If ``expected_min_SOE = true``, then the expected end-of-horizon SOE must be higuer or equal to the 'final_energy_proportion' parameter found in the 'Storage_data.csv' input file. The expected end-of-horizon SOE is set to the initial stored energy otherwise.

Optional arguments include: 
- VLGEN [MWh/$] value of curtailed generation in the SUC problem. 
- write [BOOLEAN]: whether to save simulation results.
- ...

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.