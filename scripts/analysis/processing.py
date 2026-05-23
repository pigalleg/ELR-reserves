import pandas as pd
import os
import pyarrow.parquet as pq
import re
import warnings
import numpy as np
import json


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

def parquet_to_solution(file_name, file_folder, solution_keys = None, columns_by_key=None):
    if solution_keys is None:
        solution_keys = ['demand', 'generation', 'storage', 'reserve', 'energy_reserve', 'scalar', 'generation_parameters', 'storage_parameters', 'objective_function', 'dual_variables']
    keys = [k for k in solution_keys if os.path.isfile(os.path.join(file_folder, f"{file_name}_{k}.parquet"))]
    aux = [
        read_parquet_and_convert(
            os.path.join(file_folder, f"{file_name}_{k}.parquet"),
            columns=(columns_by_key or {}).get(k),
        )
        for k in keys
    ]
    return {k: v for k, v in zip(keys, aux)}

# def _downcast_numeric(df):
#     float_cols = df.select_dtypes(include=['float64']).columns
#     int_cols = df.select_dtypes(include=['int64']).columns
#     if len(float_cols) > 0:
#         df[float_cols] = df[float_cols].apply(pd.to_numeric, downcast='float')
#     if len(int_cols) > 0:
#         df[int_cols] = df[int_cols].apply(pd.to_numeric, downcast='integer')
#     return df

def read_parquet_and_convert(file, columns=None):
    if not os.path.exists(file):
        warnings.warn(f"The file {file} does not exist.")
        return pd.DataFrame()
    columns_to_read = columns
    if columns is not None:
        available_columns = set(pq.read_schema(file).names)
        columns_to_read = [c for c in columns if c in available_columns]
        if len(columns_to_read) == 0:
            columns_to_read = None

    out = pq.read_table(file, columns=columns_to_read).to_pandas()
    out.rename(columns={'scenario': 'iteration', 'mu': 'µ'}, inplace=True) # scenario --> iteration to aling suc's with ed's output
    if 'iteration' in out.columns:
        out['iteration'] = out['iteration'].apply(lambda x: re.sub(r'^scenario', 'iteration', x))
    if 'configuration' in out.columns and 'µ' not in out.columns: # uncomment in case µ is not in the output
        out['µ'] = out['configuration'].apply(parse_configuration_to_mu)
    # return _downcast_numeric(out)
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
    columns_by_key = kwargs.pop("columns_by_key", None)

    # Stream by day and concatenate per key to avoid holding all daily dicts in memory.
    per_key_frames = {}
    for day in days:
        day_solution = parquet_to_solution(
            solution_name,
            os.path.join(solution_folder, f"n_{day}"),
            solution_keys,
            columns_by_key=columns_by_key,
        )
        for key, df in day_solution.items():
            if df.empty:
                continue
            for k, v in kwargs.items():
                df[k] = v
            per_key_frames.setdefault(key, []).append(df)

    return {
        key: pd.concat(frames, copy=False)
        for key, frames in per_key_frames.items()
    }



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

    if 'µ' not in df.columns:
        df['µ'] = df['configuration'].apply(parse_configuration_to_mu)
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


# def read_solutions(solution_folders, days, solution_keys):
#     s_uc = []
#     s_ed = []

#     for sol in ss:
#         s = sol['solution_folder']
#         s_uc_ = load_solutions("s_uc", os.path.join("..", "output", s), days, solution_keys = solution_keys,  model_type = sol['model_type'], solution_id = s)
#         if sol['model_type'] != 'stochastic':
#             s_ed_ = load_solutions("s_ed", os.path.join("..", "output", s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
#         else:
#             s_ed_ = load_solutions("s_suc", os.path.join("..", "output", s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
#         s_uc.append(s_uc_)
#         s_ed.append(s_ed_)
#     s_uc = combine_solutions(s_uc)
#     s_ed = combine_solutions(s_ed)

#     for k,v in s_uc.items():
#         if 'µ' in v.columns:
#             s_uc[k] = apply_conservative_classification(s_uc[k])
#     for k,v in s_ed.items():
#         if 'µ' in v.columns:
#             s_ed[k]= apply_conservative_classification(s_ed[k])
#     return s_uc, s_ed


# =============================================================================
# Converted Julia Functions for Supply/Demand and Reserve Calculations
# =============================================================================

import pandas as pd
import numpy as np
from typing import Optional, List, Union

# Resource ordering for consistent plotting/display
order_ = [
    "solar_photovoltaic_curtailment",
    "onshore_wind_turbine_curtailment", 
    "small_hydroelectric_curtailment",
    "loss_of_generation",
    "total_loss_of_load_ED",
    "total_loss_of_generation_ED",
    "net_generation_curtailment",
    "battery",
    "net_generation",
    "CSP",
    "CC", 
    "CT",
    "STEAM", 
    "ROR", 
    "HYDRO",
    "hydro_reservoir",
    "NUCLEAR",
    "solar_photovoltaic",
    "natural_gas_fired_combustion_turbine",
    "natural_gas_fired_combined_cycle",
    "onshore_wind_turbine",
    "hydroelectric_pumped_storage",
    "small_hydroelectric",
    "biomass",
    "total",
    "system",
    "required"
]

G_NET_GENERATION_FULL_ID = "net_generation"

def order_df(df: pd.DataFrame) -> pd.DataFrame:
    """
    Order DataFrame by predefined resource order
    
    Parameters:
    -----------
    df : pd.DataFrame
        DataFrame with 'resource' column to order
        
    Returns:
    --------
    pd.DataFrame
        Ordered DataFrame without the temporary order column
    """
    df_copy = df.copy()
    
    # Create order mapping
    order_mapping = {resource: i for i, resource in enumerate(order_)}
    
    # Add order column (use high value for resources not in order_)
    df_copy['order_'] = df_copy['resource'].map(order_mapping).fillna(len(order_))
    
    # Sort by order (descending to match Julia's rev=true)
    df_copy = df_copy.sort_values('order_', ascending=False)
    
    # Remove order column
    return df_copy.drop(columns=['order_'])

def calculate_supply_demand(solution: dict, group_by: List[str] = None) -> tuple:
    """
    Calculate supply and demand from solution data
    
    Parameters:
    -----------
    solution : dict
        Solution dictionary containing 'generation', 'demand', and optionally 'storage'
    group_by : List[str], optional
        Columns to group by. Default is ['hour', 'resource']
        
    Returns:
    --------
    tuple
        (supply_df, demand_df) - Ordered DataFrames with supply and demand data
    """
    if group_by is None:
        group_by = ['hour', 'resource']
    
    # Initialize demand calculation
    demand_cols = [col for col in group_by if col in solution['demand'].columns]
    demand = solution['demand'].groupby(demand_cols)['demand_MW'].sum().reset_index()
    
    # Add Loss of Load (LOL) if available
    if 'LOL_MW' in solution['demand'].columns:
        aux = solution['demand'].groupby(demand_cols)['LOL_MW'].sum().reset_index()
        aux = aux[aux['LOL_MW'] > 0]
        if not aux.empty:
            aux = aux.rename(columns={'LOL_MW': 'demand_MW'})
            aux['resource'] = aux['resource'] + '_loss_of_load_ED'
            demand = pd.concat([demand, aux], ignore_index=True)
    
    # Add Loss of Generation (LGEN) if available  
    if 'LGEN_MW' in solution['demand'].columns:
        aux = solution['demand'].groupby(demand_cols)['LGEN_MW'].sum().reset_index()
        aux = aux[aux['LGEN_MW'] > 0]
        if not aux.empty:
            aux = aux.rename(columns={'LGEN_MW': 'demand_MW'})
            aux['resource'] = aux['resource'] + '_loss_of_generation_ED'
            demand = pd.concat([demand, aux], ignore_index=True)
    
    # Calculate supply from generation
    supply_cols = [col for col in group_by if col in solution['generation'].columns]
    supply = solution['generation'].groupby(supply_cols)['production_MW'].sum().reset_index()
    
    # Add curtailment to supply
    if 'curtailment_MW' in solution['generation'].columns:
        aux = solution['generation'].groupby(supply_cols)['curtailment_MW'].sum().reset_index()
        aux = aux[aux['curtailment_MW'] > 0]
        if not aux.empty:
            aux = aux.rename(columns={'curtailment_MW': 'production_MW'})
            aux['resource'] = aux['resource'] + '_curtailment'
            supply = pd.concat([supply, aux], ignore_index=True)
    
    # Add storage if available
    if 'storage' in solution and solution['storage'] is not None and not solution['storage'].empty:
        storage_df = solution['storage'].fillna(0)  # Handle missing values
        storage_cols = [col for col in group_by if col in storage_df.columns]
        
        aux = storage_df.groupby(storage_cols).agg({
            'discharge_MW': 'sum',
            'charge_MW': 'sum'
        }).reset_index()
        
        # Add discharge to supply
        supply_storage = aux[supply_cols + ['discharge_MW']].rename(columns={'discharge_MW': 'production_MW'})
        supply = pd.concat([supply, supply_storage], ignore_index=True)
        
        # Add charge to demand
        demand_storage = aux[demand_cols + ['charge_MW']].rename(columns={'charge_MW': 'demand_MW'})
        demand = pd.concat([demand, demand_storage], ignore_index=True)
    
    # Filter out hour 0 if present
    if 'hour' in supply.columns:
        supply = supply[supply['hour'] != 0]
    if 'hour' in demand.columns:
        demand = demand[demand['hour'] != 0]
    
    return order_df(supply), order_df(demand)

def calculate_reserve(reserve: pd.DataFrame, 
                     required_reserve: Optional[pd.DataFrame] = None, 
                     group_by: List[str] = None) -> pd.DataFrame:
    """
    Calculate reserve up and down from reserve data
    
    Parameters:
    -----------
    reserve : pd.DataFrame
        Reserve DataFrame with reserve_up_MW and reserve_down_MW columns
    required_reserve : pd.DataFrame, optional
        Required reserve data to append
    group_by : List[str], optional
        Columns to group by. Default is ['hour', 'resource']
        
    Returns:
    --------
    pd.DataFrame
        Aggregated and ordered reserve data
    """
    if group_by is None:
        group_by = ['hour', 'resource']
    
    # Select required fields
    field_up_dn = ['reserve_up_MW', 'reserve_down_MW']
    
    # Get available columns from group_by that exist in reserve
    available_group_by = [col for col in group_by if col in reserve.columns]
    required_cols = available_group_by + field_up_dn
    
    # Select only available columns
    available_cols = [col for col in required_cols if col in reserve.columns]
    aux = reserve[available_cols].copy()
    
    # Fill missing values with 0
    for col in field_up_dn:
        if col in aux.columns:
            aux[col] = aux[col].fillna(0)
    
    # Group and sum
    reserve_result = aux.groupby(available_group_by)[field_up_dn].sum().reset_index()
    
    # Add required reserve if provided
    if required_reserve is not None and not required_reserve.empty:
        aux_req = required_reserve.copy()
        
        # Select available columns for required reserve
        req_cols = [col for col in (available_group_by + field_up_dn) if col in aux_req.columns]
        aux_req = aux_req[req_cols]
        aux_req['resource'] = 'required'
        
        reserve_result = pd.concat([reserve_result, aux_req], ignore_index=True)
    
    return order_df(reserve_result)

def calculate_battery_reserve(solution_storage: pd.DataFrame, 
                             solution_reserve: pd.DataFrame, 
                             efficiency: float = 0.92) -> pd.DataFrame:
    """
    Calculate battery reserve with efficiency considerations
    
    Parameters:
    -----------
    solution_storage : pd.DataFrame
        Storage solution data
    solution_reserve : pd.DataFrame  
        Reserve solution data
    efficiency : float, optional
        Battery efficiency. Default is 0.92
        
    Returns:
    --------
    pd.DataFrame
        Battery reserve data with effective reserve calculations
    """
    # Define variables to extract
    variables_to_get = ['r_id', 'hour', 'SOE_MWh', 'reserve_up_MW', 'reserve_down_MW', 
                       'envelope_up_MWh', 'envelope_down_MWh', 'iteration']
    
    # Get available fields from both dataframes
    fields_storage = [col for col in variables_to_get if col in solution_storage.columns]
    fields_reserve = [col for col in variables_to_get if col in solution_reserve.columns]
    
    # Find common grouping columns
    group_by = ['r_id', 'hour', 'iteration']
    available_group_by = [col for col in group_by if col in fields_storage and col in fields_reserve]
    
    # Filter battery data from reserve
    battery_reserve = solution_reserve[solution_reserve['resource'] == 'battery'][fields_reserve]
    
    # Join storage and battery reserve data
    if available_group_by:
        out = pd.merge(
            solution_storage[fields_storage],
            battery_reserve,
            on=available_group_by,
            how='inner'
        )
    else:
        # If no common columns, return empty dataframe
        return pd.DataFrame()
    
    # Group by relevant columns (exclude r_id from grouping but keep others)
    group_cols = [col for col in available_group_by if col != 'r_id']
    
    if group_cols:
        # Aggregate by group columns
        numeric_cols = [col for col in out.columns if col not in group_cols and pd.api.types.is_numeric_dtype(out[col])]
        out = out.groupby(group_cols)[numeric_cols].sum().reset_index()
    
    # Calculate effective reserves
    if 'reserve_down_MW' in out.columns:
        out['reserve_down_MW_eff'] = out['reserve_down_MW'] * efficiency
    
    if 'reserve_up_MW' in out.columns:
        out['reserve_up_MW_eff'] = -out['reserve_up_MW'] * (1 / efficiency)
    
    return out

# def parse_configuration_to_mu(x: Union[str, float]) -> float:
#     """
#     Parse configuration string to extract mu value (Python version)
    
#     Parameters:
#     -----------
#     x : str or float
#         Configuration string or value to parse
        
#     Returns:
#     --------
#     float
#         Parsed mu value or 1.0 if no match found
#     """
#     import re
    
#     if pd.isna(x):
#         return 1.0
    
#     x_str = str(x)
    
#     # First pattern: base_ramp_storage_envelopes_up_X_dn_Y
#     expr_1 = r"base_ramp_storage_envelopes_up_(\\w+)_dn_(\\w+)"
#     match_1 = re.search(expr_1, x_str)
    
#     if match_1:
#         # Replace underscores with dots and convert to float
#         return float(match_1.group(1).replace("_", "."))
    
#     # Second pattern: base_ramp_storage_envelopes_X  
#     expr_2 = r"base_ramp_storage_envelopes_(\\w+)"
#     match_2 = re.search(expr_2, x_str)
    
#     if match_2:
#         return match_2.group(1)  # Return as string
    
#     # Default return value
#     return 1.0

# Additional utility functions for completeness
def filter_day(day: int, df: pd.DataFrame) -> pd.DataFrame:
    """
    Filter DataFrame for specific day
    
    Parameters:
    -----------
    day : int
        Day to filter for
    df : pd.DataFrame
        DataFrame with 'day' column
        
    Returns:
    --------
    pd.DataFrame
        Filtered DataFrame
    """
    if 'day' in df.columns:
        return df[df['day'] == day].copy()
    return df

# def combine_solutions(solutions: List[dict], keys: List[str]) -> dict:
#     """
#     Combine multiple solution dictionaries
    
#     Parameters:
#     -----------
#     solutions : List[dict]
#         List of solution dictionaries
#     keys : List[str] 
#         Keys to combine from solutions
        
#     Returns:
#     --------
#     dict
#         Combined solution dictionary
#     """
#     combined = {}
    
#     for key in keys:
#         dfs_for_key = []
#         for solution in solutions:
#             if key in solution and solution[key] is not None:
#                 dfs_for_key.append(solution[key])
        
#         if dfs_for_key:
#             combined[key] = pd.concat(dfs_for_key, ignore_index=True)
#         else:
#             combined[key] = pd.DataFrame()
    
#     return combined