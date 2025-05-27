import pandas as pd
import os
import pyarrow.parquet as pq
import re
import warnings
import numpy as np


def parse_configuration_to_mu(x):
    match_obj = re.match(r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)", str(x))
    if match_obj:
        return float(match_obj.group(1).replace("_", "."))
    else:
        return 1

def parquet_to_solution(file_name, file_folder, solution_keys = None):
    if solution_keys is None:
        solution_keys = ['demand', 'generation', 'storage', 'reserve', 'energy_reserve', 'scalar', 'generation_parameters', 'storage_parameters', 'objective_function', 'dual_variables']
    keys = [k for k in solution_keys if os.path.isfile(os.path.join(file_folder, f"{file_name}_{k}.parquet"))]
    aux = [read_parquet_and_convert(os.path.join(file_folder, f"{file_name}_{k}.parquet")) for k in keys]
    return {k: v for k, v in zip(keys, aux)}

def read_parquet_and_convert(file):
    print(file)
    if not os.path.exists(file):
        warnings.warn(f"The file {file} does not exist.")
        return pd.DataFrame()
    out = pq.read_table(file).to_pandas()
    # for col in out.select_dtypes(include=['object']).columns:
    #     out[col] = pd.to_numeric(out[col], errors='ignore')
    # out.index = pd.MultiIndex.from_tuples(out.index, names=indices_)
    out.rename(columns={'scenario': 'iteration', 'mu': 'µ'}, inplace=True) # scenario --> iteration to aling suc's with ed's output
    if 'iteration' in out.columns:
        out['iteration'] = out['iteration'].apply(lambda x: re.sub(r'^scenario', 'iteration', x))
    # if 'mu' in out.columns:
        # out.rename(columns={'mu': 'µ'}, inplace=True)
        # out.set_index('µ', append=True, inplace=True)
        # out.sort_values(by='µ', inplace=True)
        # out.set_index('µ', append=True, inplace=True)
    if 'configuration' in out.columns:
        out['µ'] = out['configuration'].apply(parse_configuration_to_mu)
        # out.sort_values(by=['hour','µ',], inplace=True)
      

        # out.set_index('µ', append=True, inplace=True)
        # out.drop(columns='µ', inplace=True)
        
    # indices_ = ['µ', 'configuration', 'iteration', 'day', 'r_id', 'hour']
    # indices_ = [idx for idx in indices_ if idx in out.columns]
    # if indices_:
    #     out.set_index(pd.MultiIndex.from_frame(out[indices_], names=indices_), inplace=True)
    #     out.drop(columns=indices_, inplace=True)
    return out

def load_solutions(solution_name, solution_folder, days, **kwargs):
    """
    Load and combine solution data from multiple parquet files.

    This function reads solution data from parquet files located in the specified 
    folder, combines them into a single dictionary of DataFrames, and applies 
    additional keyword arguments to each DataFrame.

    Parameters:
    -----------
    solution_name : str
        The name of the solution to load.
    solution_folder : str
        The folder where the solution parquet files are located.
    days : list of str
        A list of day identifiers to load. Each day identifier will be prefixed 
        with 'n_' to form the filename.
    **kwargs : dict
        Additional keyword arguments to add as columns to each DataFrame in the 
        resulting dictionary.

    Returns:
    --------
    dict of pd.DataFrame
        A dictionary where keys are the combined keys from all solutions and 
        values are the concatenated DataFrames for each key.

    Example:
    --------
    >>> load_solutions('solution1', '/path/to/solutions', ['day1', 'day2'], extra_col='value')
    {'key1': DataFrame1, 'key2': DataFrame2, ...}
    """
    solution_keys = kwargs.pop("solution_keys", None)
    solutions = [parquet_to_solution(solution_name, os.path.join(solution_folder, s), solution_keys) for s in [f"n_{d}" for d in days]]
    return combine_solutions(solutions, **kwargs)



def combine_solutions(solutions, **kwargs):
    solutions = [s for s in solutions if s]  # cleaning empty
    all_keys = set().union(*(d.keys() for d in solutions))
    solutions_dict = {k: pd.concat([s[k] for s in solutions if k in s.keys()]) for k in all_keys}
    for s in solutions_dict.keys():
        for k, v in kwargs.items():
            solutions_dict[s][k] = v
        # solutions_dict[s] = add_kwargs_as_indices(solutions_dict[s], **kwargs)
    return solutions_dict

def add_fields(df, **kwargs):
    for k, v in kwargs.items():
        df[k] = v
    cols = list(kwargs.keys()) + [col for col in df.columns if col not in list(kwargs.keys())]
    df = df[cols]
    return df

def add_kwargs_as_indices(df, **kwargs):
    for k, v in kwargs.items():
        df[k] = v
    df.set_index(list(kwargs.keys()), append=True, inplace=True)
    df = df.reorder_levels(list(kwargs.keys()) + [name for name in df.index.names if name not in list(kwargs.keys())])
    return df
    # print(df.index.names)
    # df.drop(columns=list(kwargs.keys()), inplace=True)
       
def filter_demand(expected_load, loads_to_filter, required_reserve):
    """
    Clamp all columns in loads_to_filter (except 'hour' and optionally 'day')
    to the range [expected_load.demand - required_reserve.reserve_down_MW,
                  expected_load.demand + required_reserve.reserve_up_MW]
    for each row.
    """
    select = ['hour', 'day'] if 'day' in loads_to_filter.columns else ['hour']
    # Ensure indices align for broadcasting
    loads_to_filter = loads_to_filter.copy()
    for idx, row in loads_to_filter.iterrows():
        mask = [col for col in loads_to_filter.columns if col not in select]
        demand = expected_load.loc[idx, 'demand'] if 'demand' in expected_load.columns else expected_load['demand'].iloc[idx]
        reserve_down = required_reserve.loc[idx, 'reserve_down_MW'] if 'reserve_down_MW' in required_reserve.columns else required_reserve['reserve_down_MW'].iloc[idx]
        reserve_up = required_reserve.loc[idx, 'reserve_up_MW'] if 'reserve_up_MW' in required_reserve.columns else required_reserve['reserve_up_MW'].iloc[idx]
        lower = demand - reserve_down
        upper = demand + reserve_up
        loads_to_filter.loc[idx, mask] = np.clip(row[mask], lower, upper)
    return loads_to_filter