#!/usr/bin/env python3
import argparse
import os
import sys
import pandas as pd
from typing import List, Dict

# Assume processing.py is importable (adjust path if needed)
sys.path.append(os.path.join(os.path.dirname(__file__), "..", "..", "notebooks"))
try:
    from processing import (
        read_parquet_and_convert,
        add_fields,
        apply_conservative_classification
    )
except ImportError:
    print("Error: could not import processing module. Adjust sys.path.", file=sys.stderr)
    sys.exit(1)

DEFAULT_SOLUTIONS: List[Dict[str, str]] = [
    {"solution_folder": "RTS-GMLC_v32.3s", "model_type": "envelope"},
    {"solution_folder": "RTS-GMLC_v32.2s", "model_type": "e-reserve"},
]

def parse_solution_arg(arg: str) -> Dict[str, str]:
    """
    Format: folder[:model_type]
    If model_type omitted -> envelope.
    """
    if ":" in arg:
        folder, mtype = arg.split(":", 1)
    else:
        folder, mtype = arg, "envelope"
    return {"solution_folder": folder, "model_type": mtype}

def load_kpi_pair(base_output_dir: str, sol: Dict[str, str]):
    s = sol["solution_folder"]
    model_type = sol["model_type"]
    base = os.path.join(base_output_dir, s)
    gcd_path = os.path.join(base, "all_gcd_KPI_adequacy.parquet")
    gcdi_path = os.path.join(base, "all_gcdi_KPI_adequacy.parquet")

    if not os.path.isfile(gcd_path):
        print(f"[WARN] Missing {gcd_path}; skipping.")
        return None, None

    try:
        gcd = read_parquet_and_convert(gcd_path)
    except Exception as e:
        print(f"[ERROR] Reading {gcd_path}: {e}")
        return None, None

    if not os.path.isfile(gcdi_path):
        print(f"[WARN] Missing {gcdi_path}; skipping gcdi for {s}.")
        gcdi = pd.DataFrame()
    else:
        try:
            gcdi = read_parquet_and_convert(gcdi_path)
        except Exception as e:
            print(f"[ERROR] Reading {gcdi_path}: {e}")
            gcdi = pd.DataFrame()

    gcd = add_fields(gcd, model_type=model_type, solution_id=s)
    gcdi = add_fields(gcdi, model_type=model_type, solution_id=s)
    return gcd, gcdi

# def normalize_model_type_flags(df: pd.DataFrame) -> pd.DataFrame:
#     if df.empty:
#         return df
#     if "µ" in df.columns:
#         df["model_type"] = df.apply(
#             lambda x: "conservative"
#             if ("envelope" in str(x["model_type"])) and (x["µ"] == 1)
#             else x["model_type"],
#             axis=1,
#         )
#     return df


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

# def add_non_conservative_flag(df: pd.DataFrame) -> pd.DataFrame:
#     if df.empty or "µ" not in df.columns:
#         return df
#     df["non-conservative"] = df[["model_type", "µ"]].apply(
#         lambda x: (x[0] != "envelope") + (x[0] == "envelope") * (x[1] < 1),
#         axis=1,
#     )
#     return df

def rename_parameters(df: pd.DataFrame) -> pd.DataFrame:
    renames = {}
    if "µ" in df.columns:
        renames["µ"] = "mu"
    if "ρ" in df.columns:
        renames["ρ"] = "rho"
    if renames:
        df = df.rename(columns=renames)
    return df

def save_outputs(gcd: pd.DataFrame, gcdi: pd.DataFrame, out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    gcd.to_csv(os.path.join(out_dir, "gcd_KPI_adequacy.csv"), index=False)
    gcdi.reset_index(drop=True).to_csv(
        os.path.join(out_dir, "gcdi_KPI_adequacy.csv"), index=False
    )
    print(f"[INFO] Saved outputs to {out_dir}")

def main():
    parser = argparse.ArgumentParser(
        description="Generate KPI adequacy CSVs from solution folders."
    )
    parser.add_argument(
        "--solution",
        action="append",
        help="Add a solution (folder[:model_type]). Repeatable.",
    )
    parser.add_argument(
        "--base-output-dir",
        default=os.path.join(".", "output"),
        help="Base directory containing solution folders (default: ../output)",
    )
    parser.add_argument(
        "--output-dir",
        default="reports",
        help="Directory to write consolidated CSVs (default: reports)",
    )
    parser.add_argument(
        "--no-save", action="store_true", help="Do not write output CSV files."
    )
    parser.add_argument(
        "--list-defaults",
        action="store_true",
        help="List default solution entries and exit.",
    )

    args = parser.parse_args()

    if args.list_defaults:
        for s in DEFAULT_SOLUTIONS:
            print(f"{s['solution_folder']}:{s['model_type']}")
        return 0

    if args.solution:
        solutions = [parse_solution_arg(a) for a in args.solution]
    else:
        solutions = DEFAULT_SOLUTIONS


    gcd_list = []
    gcdi_list = []
    for sol in solutions:
        gcd, gcdi = load_kpi_pair(args.base_output_dir, sol)
        if gcd is not None and not gcd.empty:
            gcd_list.append(gcd)
        if gcdi is not None and not gcdi.empty:
            gcdi_list.append(gcdi)

    if not gcd_list or not gcdi_list:
        print("[ERROR] No KPI data loaded. Exiting.")
        return 1

    gcd_all = pd.concat(gcd_list, ignore_index=True)
    gcdi_all = pd.concat(gcdi_list, ignore_index=True)

    # gcd_all = normalize_model_type_flags(gcd_all)
    # gcdi_all = normalize_model_type_flags(gcdi_all)

    apply_conservative_classification(gcd_all)
    apply_conservative_classification(gcdi_all)

    gcd_all = rename_parameters(gcd_all)
    gcdi_all = rename_parameters(gcdi_all)


    if not args.no_save:
        save_outputs(gcd_all, gcdi_all, args.output_dir)

    print("[INFO] Done.")
    return 0

if __name__ == "__main__":
    sys.exit(main())

# run examples
# python scripts/analysis/save_kpi_adequacy.py --solution RTS-GMLC_v32.3s:envelope --solution RTS-GMLC_v32.2s:e-reserve  --output-dir notebooks
# python ./scripts/analysis/save_kpi_adequacy.py --list-defaults