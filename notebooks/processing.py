import pandas as pd
import os
import pyarrow.parquet as pq
import re
import warnings
import numpy as np


def parse_configuration_to_mu(x):
    """
    Parse configuration string to extract mu value.
    
    Parameters:
    -----------
    x : str
        Configuration string to parse
        
    Returns:
    --------
    float, str, or None
        - Float value if matches first pattern (base_ramp_storage_envelopes_up_X_dn_Y)
        - String value if matches second pattern (base_ramp_storage_envelopes_X)  
        - None if no pattern matches
    """
    x_str = str(x)
    
    # Pattern 1: base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)
    expr_1 = r"base_ramp_storage_envelopes_up_(\w+)_dn_(\w+)"
    match_1 = re.search(expr_1, x_str)
    if match_1:
        return float(match_1.group(1).replace("_", "."))
    
    # Pattern 2: base_ramp_storage_envelopes_(\w+)
    expr_2 = r"base_ramp_storage_envelopes_(\w+)"
    match_2 = re.search(expr_2, x_str)
    if match_2:
        return match_2.group(1)
    
    # No pattern matches
    return None

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
    out.rename(columns={'scenario': 'iteration', 'mu': 'µ'}, inplace=True) # scenario --> iteration to aling suc's with ed's output
    if 'iteration' in out.columns:
        out['iteration'] = out['iteration'].apply(lambda x: re.sub(r'^scenario', 'iteration', x))
    # if 'configuration' in out.columns: # uncomment in case µ is not in the output
    #     out['µ'] = out['configuration'].apply(parse_configuration_to_mu)
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

def transform_to_internal_time(df):
    """
    This function transforms the time in the dataframe to internal time (1-24)
    It assumes that the hour is in the range of 1-8760
    """
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


def classify_conservative_model(row):
    """
    Classify model type as 'conservative' if it's an envelope model with specific µ values.
    
    Parameters:
    -----------
    row : pandas.Series
        A row from a DataFrame containing 'model_type' and 'µ' columns
        
    Returns:
    --------
    str
        'conservative' if model_type contains 'envelope' and µ meets one of the conditions:
        - µ == 1
        - µ == 'mu_1'  
        - 'conservative' in µ (as string)
        otherwise returns the original model_type
    """
    mu_conditions = (
        (row['µ'] == 1) or 
        (row['µ'] == 'mu_1') or 
        ('conservative' in str(row['µ']))
    )
    
    if ('envelope' in row['model_type']) and mu_conditions:
        return 'conservative'
    else:
        return row['model_type']

def apply_conservative_classification(df):
    """
    Apply conservative model classification to a DataFrame in place.
    
    Parameters:
    -----------
    df : pandas.DataFrame
        DataFrame containing 'model_type' and 'µ' columns.
        This DataFrame will be modified in place.
        
    Returns:
    --------
    pandas.DataFrame
        The same DataFrame with updated model_type column (for method chaining)
    """
    if 'µ' in df.columns:
        df['model_type'] = df.apply(classify_conservative_model, axis=1)
    return df

def read_KPI_adequacy(solution_folders):

    gcd_KPI_adequacy = []
    gcdi_KPI_adequacy = []
    for sol in solution_folders:
        s = sol['solution_folder']
        gcd_KPI_adequacy_ = read_parquet_and_convert( os.path.join("..", "output", s, "all_gcd_KPI_adequacy.parquet"))
        gcd_KPI_adequacy_ = add_fields(gcd_KPI_adequacy_, model_type = sol['model_type'], solution_id = s) 

        gcdi_KPI_adequacy_ = read_parquet_and_convert( os.path.join("..", "output", s, "all_gcdi_KPI_adequacy.parquet"))
        gcdi_KPI_adequacy_ = add_fields(gcdi_KPI_adequacy_, model_type = sol['model_type'], solution_id = s)

        gcd_KPI_adequacy.append(gcd_KPI_adequacy_)
        gcdi_KPI_adequacy.append(gcdi_KPI_adequacy_)


    gcd_KPI_adequacy = pd.concat(gcd_KPI_adequacy)
    gcdi_KPI_adequacy = pd.concat(gcdi_KPI_adequacy)
    apply_conservative_classification(gcdi_KPI_adequacy)
    apply_conservative_classification(gcd_KPI_adequacy)

    return gcd_KPI_adequacy, gcdi_KPI_adequacy