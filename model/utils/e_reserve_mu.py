

import os, sys
import pandas as pd
import argparse
import numpy as np

def transform_to_internal_time(df):
    df = df.copy()  # Make a copy to avoid modifying the original
    
    # Transform hour columns to internal time (1-24)
    for col_name in df.columns:
        if 'hour' in col_name.lower():
            df[col_name] = ((df[col_name] - 1) % 24) + 1
    
    # Sort by the intersection of ['r_id', 'day', 'hour'] and existing columns
    sort_cols = [col for col in ['r_id', 'day', 'hour'] if col in df.columns]
    if sort_cols:
        df = df.sort_values(sort_cols).reset_index(drop=True)
    
    return df

DEFAULT_SOLUTIONS: list[dict[str, str]] = [
    {"input_folder": "RTS-GMLC_v2.4.2", "output_folder": "."},
]

def solve_system(reserve, energy_reserve_max, column_name):
    # Solve A x = B iteratively (forward substitution) without np.linalg.solve
    n = reserve.index.size
    r = reserve.to_numpy()
    b = pd.Series(energy_reserve_max).reindex(reserve.index).to_numpy()

    x = np.zeros(n, dtype=float)
    for i in range(n):
        s = float(r[:i] @ x[:i]) if i else 0.0
        if r[i] == 0:
            if np.isclose(b[i] - s, 0.0):
                x[i] = 0.0
            else:
                raise ValueError("Singular system: zero diagonal coefficient.")
        else:
            x[i] = (b[i] - s) / r[i]
            x[i] = float(np.clip(x[i], 0.0, 1.0))

    return pd.DataFrame({column_name: x}, index=reserve.index.get_level_values('hour'))

# def solve_system(reserve, energy_reserve_max, column_name):
    # # Original method using np.linalg.solve
    # n = reserve.index.size
    # # Create matrix A as a lower triangular matrix for up reserves
    # A = np.zeros((n,n))
    # for i in range(n):
    #     for j in range(n):
    #         if i >= j:  # Lower triangular condition
    #             A[i,j] = reserve.iloc[j]

    # # Get vector B as the maximum energy reserve requirement for each hour
    # B = energy_reserve_max
    # return  pd.DataFrame({column_name: np.linalg.solve(A, B)}, index=reserve.index.get_level_values('hour'))

    

def calculate_mu(required_reserve, required_energy_reserve):
    required_reserve = transform_to_internal_time(required_reserve)
    required_energy_reserve = transform_to_internal_time(required_energy_reserve)

    required_reserve.set_index(['day','hour'], inplace = True)
    required_energy_reserve.rename(columns = {'i_hour': 'hour_i', 't_hour':'hour', 'reserve_up_MW':'energy_reserve_up_MW', 'reserve_down_MW':'energy_reserve_down_MW'}, inplace=True)
    #####
    # required_energy_reserve_max = required_energy_reserve.groupby(['day', 'hour',]).max() # comment or uncomment this and following line to use max or not
    required_energy_reserve_max = required_energy_reserve[required_energy_reserve.hour_i ==1].set_index(['day','hour']).sort_index()
    #####
    requirements_all = pd.concat([required_reserve, required_energy_reserve_max], axis=1)
    return pd.concat(
        [requirements_all.groupby('day').apply(lambda x: solve_system(x.reserve_up_MW, x.energy_reserve_up_MW, 'mu_up')),
        requirements_all.groupby('day').apply(lambda x: solve_system(x.reserve_down_MW, x.energy_reserve_down_MW, 'mu_down'))
        ], axis = 1
    )

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run energy reserve utility.")

    default_input = os.path.join("./input", DEFAULT_SOLUTIONS[0]["input_folder"])
    default_output = DEFAULT_SOLUTIONS[0]["output_folder"]
    
    parser.add_argument(
        "-i", "--input_folder",
        default=default_input,
        help=f"Path to input folder (default: {default_input})",
    )
    parser.add_argument(
        "-o", "--output_folder",
        default=default_output,
        help=f"Path to output folder (default: {default_output})",
    )
    args = parser.parse_args()


    required_reserve = pd.read_csv(os.path.join(args.input_folder, 'uc','Reserve.csv')) 
    required_energy_reserve = pd.read_csv(os.path.join(args.input_folder, 'uc','Energy reserve.csv'))

    calculate_mu(required_reserve, required_energy_reserve).to_csv(os.path.join(args.output_folder, 'mu.csv'), index=True)

    sys.exit()
