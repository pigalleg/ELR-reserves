# Notebook Data Map

Static map of active `input/{dataset}` and `output/{run}` references in the
27 notebooks under `notebooks/`. It was generated from executable code cells;
commented examples and rendered notebook output are excluded.

## Active References

| Notebooks | Input datasets | Output runs |
| --- | --- | --- |
| `PSCC_1.ipynb` | `RTS-GMLC_v2.4.2` | `RTS-GMLC_v32.3s`, `RTS-GMLC_v32.1s` |
| `PSCC_3.ipynb` | `RTS-GMLC_v2.1` | Configuration-driven |
| `MPhil_cost_analysis.ipynb` | None explicit | `RTS-GMLC_v32.3s`, `RTS-GMLC_v32.5s` |
| `day_ahead_schedules.ipynb`, `dual_variables.ipynb`, `envelopes.ipynb`, `mu_estimation.ipynb` | None explicit | `RTS-GMLC_v32.3s`, `RTS-GMLC_v32.1s` |
| `dispatch.ipynb` | None | `RTS-GMLC_v32.3s` |
| `conservative_vs_e_reserve_study.ipynb`, `cost_differences_analysis.ipynb`, `metrics.ipynb`, `pca_cost_analysis.ipynb` | None explicit | `RTS-GMLC_v32.3s`, `RTS-GMLC_v32.1s` |
| `empirical_mu_eens.ipynb`, `empirical_mu_eens_ignore.ipynb` | `base_case_increased_storage_energy_v8.{0.0,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,0.99}.4` | None |
| `archives/ESA/ESA_empirical_mu.ipynb` | `base_case_increased_storage_energy_v8.0.8.4` | Configuration-driven |

## Configuration-Driven References

The following notebooks construct `input/{dataset}` or `output/{run}` paths
from variables such as `s`, `ss`, `solution_folder`, or `input_folder`. Their
currently selected values were not fully resolvable as literal paths in the
same notebook code.

| Notebook | Reference |
| --- | --- |
| `MPhil_demand_&_reserves_analysis.ipynb` | Input dataset from `solution_folder` |
| `MPhil_multipliers_benchmark.ipynb` | Input datasets from `solution_folder` variables |
| `PSCC_2.ipynb` | Output run from configuration |
| `binding_constraints_analysis.ipynb` | Output run from configuration |
| `binding_constraints_analysis_all_days.ipynb` | Output run from configuration |
| `compare_objective_value.ipynb` | Output run from configuration |
| `convergence.ipynb` | Output run from configuration |
| `model_differences_analysis_ignore.ipynb` | No explicit dataset or run found |
| `archives/ESA/ESA_average_mu.ipynb` | No `input/` or `output/` reference found |
| `archives/ESA/ESA_metrics.ipynb` | Output run from configuration |

## DVC Scope

Track each selected dataset or run as a directory with DVC, for example:

```sh
dvc add input/RTS-GMLC_v2.4.2
dvc add output/RTS-GMLC_v32.3s
```

This repository ignores `input/*` and `output/*`, while allowing the
top-level DVC pointer files (`input/*.dvc`, `output/*.dvc`) to be committed.
DVC initialisation, data tracking, and remote configuration are intentionally
deferred until requested.