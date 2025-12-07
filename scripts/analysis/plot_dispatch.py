#lOAD PACKAGES
#

import pandas as pd
import os
import sys
import argparse
import plotly.express as px
import plotly.io as pio

# Ensure notebooks directory is importable
# sys.path.append(os.path.join(os.path.dirname(__file__), "..", "..", "notebooks"))

# Open plots in external browser window
pio.renderers.default = "browser"

try:
    from processing import (
        load_solutions,
        combine_solutions,
        apply_conservative_classification,
        calculate_supply_demand,
        calculate_reserve,
    )
    from plotting import (
        plot_reserve_by_fieldy,
        plot_supply_demand,
        plot_reserve
    )
    
except ImportError:
    print("Import failed.", file=sys.stderr)
    sys.exit(1)




def parse_solution_arg(arg: str):
    """
    Format: folder[:model_type]
    If model_type omitted -> envelope.
    """
    if ":" in arg:
        folder, mtype = arg.split(":", 1)
    else:
        folder, mtype = arg, "envelope"
    return {"solution_folder": folder, "model_type": mtype}


def parse_days_arg(days_arg: str):
    """
    Parse comma separated days string into list of ints
    """
    if not days_arg:
        return None
    parts = [p.strip() for p in days_arg.split(",") if p.strip() != ""]
    return [int(p) for p in parts]


def main():
    parser = argparse.ArgumentParser(description="Plot dispatch for solutions")
    parser.add_argument(
        "--solution",
        action="append",
        help="Add a solution (folder[:model_type]). Repeatable.",
    )
    parser.add_argument(
        "--base-output-dir",
        default=os.path.join("..", "..", "output"),
        help="Base directory containing solution folders (default: ../../output)",
    )
    parser.add_argument(
        "--days",
        help="Comma-separated list of days to load (e.g. 131,103). If omitted uses defaults in script.",
    )
    parser.add_argument(
        "--model-type",
        dest="model_type",
        default="envelope",
        help="Model type to plot (default: envelope)."
    )
    parser.add_argument(
        "--day",
        type=int,
        help="Single day to display (overrides days[0] for plotting)."
    )
    parser.add_argument(
        "--no-show",
        action="store_true",
        default=True,
        help="Do not open plots in browser (useful for CI)."
    )
    args = parser.parse_args()

    # Default solutions (kept from the script if none provided)
    default_ss = [
        {'solution_folder': "RTS-GMLC_v32.3s", 'model_type': 'envelope'},
        {'solution_folder': "RTS-GMLC_v32.1s", 'model_type': 'e-reserve'},
    ]

    if args.solution:
        ss = [parse_solution_arg(a) for a in args.solution]
    else:
        ss = default_ss

    # parse days
    days_parsed = parse_days_arg(args.days)
    if days_parsed is None:
        days = [131, 103]
    else:
        days = days_parsed

    # which model_type to display
    model_type_ = args.model_type

    # load solutions (same logic as before)
    s_uc = []
    s_ed = []

    solution_keys = ['demand','generation','storage','reserve','energy_reserve']
    for sol in ss:
        s = sol['solution_folder']
        s_uc_ = load_solutions("s_uc", os.path.join(args.base_output_dir, s), days, solution_keys = solution_keys,  model_type = sol['model_type'], solution_id = s)
        if sol['model_type'] != 'stochastic':
            s_ed_ = load_solutions("s_ed", os.path.join(args.base_output_dir, s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
        else:
            s_ed_ = load_solutions("s_suc", os.path.join(args.base_output_dir, s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
        s_uc.append(s_uc_)
        s_ed.append(s_ed_)

    s_uc = combine_solutions(s_uc)
    s_ed = combine_solutions(s_ed)


    for k,v in s_uc.items():
        if 'µ' in v.columns:
            s_uc[k] = apply_conservative_classification(s_uc[k])
    for k,v in s_ed.items():
        if 'µ' in v.columns:
            s_ed[k]= apply_conservative_classification(s_ed[k])


    # Define group_by and calculate supply, demand, and reserves
    group_by = ['configuration', 'day', 'model_type', 'solution_id']

    # Calculate supply and demand for UC and ED
    supply_uc, demand_uc = calculate_supply_demand(s_uc, ['hour', 'resource'] + group_by)
    supply_ed, demand_ed = calculate_supply_demand(s_ed, ['hour', 'resource', 'iteration'] + group_by)


    # Handle reserves calculation
    reserve_uc = calculate_reserve(s_uc['reserve'], None, ['hour', 'resource'] + group_by)

    if len(s_uc.get('energy_reserve', [])) > 0:
        s_uc_reserve = s_uc['energy_reserve'][s_uc['energy_reserve']['hour'] == s_uc['energy_reserve']['hour_i']]
        s_uc_reserve = s_uc_reserve.drop('hour_i', axis=1)
        s_uc_reserve = s_uc_reserve.rename(columns={
            'energy_reserve_up_MW': 'reserve_up_MW',
            'energy_reserve_down_MW': 'reserve_down_MW'
        })
        reserve_uc = pd.concat([calculate_reserve(s_uc_reserve, None, ['hour', 'resource'] + group_by),reserve_uc], axis=0) 

    # Calculate commitments
    commit_uc = s_uc['generation'].groupby(['resource', 'configuration', 'day', 'hour'])['commit'].sum().reset_index()
    commit_ed = s_ed['generation'].groupby(['resource', 'configuration', 'day', 'iteration', 'hour'])['commit'].sum().reset_index()

    # pick day to plot: --day overrides
    if args.day is not None:
        day_ = args.day
    else:
        day_ = days[0] if len(days) > 0 else None

    if day_ is None:
        print("No day selected for plotting. Exiting.", file=sys.stderr)
        sys.exit(1)

    # Prepare slices and plot
    try:
        supply_uc_ = supply_uc[(supply_uc.day == day_)]
        demand_uc_ = demand_uc[(demand_uc.day == day_)]
        reserve_uc_ = reserve_uc[(reserve_uc.day == day_)]
    except Exception as e:
        print(f"Error slicing dataframes for day/model_type: {e}", file=sys.stderr)
        sys.exit(1)
    fig = plot_supply_demand(supply_uc_, demand_uc_, title=model_type_, column_key='model_type')
    # fig = plot_supply_demand(supply_uc_, demand_uc_, model_type_)
    if args.no_show:
        fig.write_html("supply_demand.html", auto_open=False)
        print("Wrote supply_demand.html")
    else:
        fig.show()

    fig = plot_reserve(reserve_uc_, model_type_)
    if args.no_show:
        fig.write_html("reserve.html", auto_open=False)
        print("Wrote reserve.html")
    else:
        fig.show()


if __name__ == "__main__":
    main()
