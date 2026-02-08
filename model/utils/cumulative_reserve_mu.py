import os
import sys
import argparse
import pandas as pd
import numpy as np


def transform_to_internal_time(df):
    df = df.copy()

    for col_name in df.columns:
        if "hour" in col_name.lower():
            df[col_name] = ((df[col_name] - 1) % 24) + 1

    sort_cols = [col for col in ["r_id", "day", "hour"] if col in df.columns]
    if sort_cols:
        df = df.sort_values(sort_cols).reset_index(drop=True)

    return df


DEFAULT_SOLUTIONS: list[dict[str, str]] = [
    {"input_folder": "RTS-GMLC_v2.1", "output_folder": "."},
]


def calculate_mu_for_each_imbalance(demand, random_demand, reserve):
    """
    Calculate the reserve margin (mu) for each imbalance scenario.

    This function computes the cumulative imbalance and reserve values, then calculates
    the reserve margin ratio (mu) which represents how much reserve is available relative
    to the cumulative imbalance experienced.

    Parameters
    ----------
    demand : pd.DataFrame
        DataFrame containing actual demand values with columns including "demand".
        Expected to have a datetime-like index or columns that can be transformed.
    random_demand : pd.DataFrame
        DataFrame containing random/forecasted demand values with the same structure as demand.
        Used to calculate imbalances (forecast errors).
    reserve : pd.DataFrame
        DataFrame containing reserve capacity with columns "reserve_up_MW" and "reserve_down_MW".

    Returns
    -------
    pd.DataFrame
        DataFrame with columns:
        - day : Day identifier
        - hour : Hour identifier
        - iteration : Scenario/iteration identifier
        - mu_up : Reserve margin ratio for upward imbalance (cumsum_imbalance_up / cumsum_reserve_up)
        - mu_down : Reserve margin ratio for downward imbalance (cumsum_imbalance_down / cumsum_reserve_down)

    Notes
    -----
    - Imbalance is calculated as the difference between random_demand and actual demand.
    - Cumulative imbalance is calculated per day and iteration for up/down components.
    - Cumulative reserve is calculated per day.
    - sort_index() sorts by the index levels in order: first by "day", then by "hour".
    """
    demand = transform_to_internal_time(demand)
    random_demand = transform_to_internal_time(random_demand)
    reserve = transform_to_internal_time(reserve)

    demand.set_index(["day", "hour"], inplace=True)
    random_demand.set_index(["day", "hour"], inplace=True)
    reserve.set_index(["day", "hour"], inplace=True)

    imbalance = random_demand.sub(demand["demand"], axis=0, level=["day", "hour"])
    imbalance = imbalance.sort_index() # outer then inner: first by "day", then by "hour"
    reserve = reserve.sort_index() # outer then inner: first by "day", then by "hour"

    imbalance = (
        imbalance
        .stack()
        .reset_index(name="imbalance_MW")
        .rename(columns={"level_2": "iteration"})
    )

    imbalance["imbalance_up_MW"] = imbalance["imbalance_MW"].clip(lower=0)
    imbalance["imbalance_down_MW"] = (-1) * imbalance["imbalance_MW"].clip(upper=0)

    cum_imbalance = imbalance[["day", "hour", "iteration", "imbalance_up_MW", "imbalance_down_MW"]].copy()
    cum_imbalance[["imbalance_up_MW", "imbalance_down_MW"]] = (
        cum_imbalance
        .groupby(["day", "iteration"])[["imbalance_up_MW", "imbalance_down_MW"]]
        .cumsum()
    )
    cum_imbalance = cum_imbalance.rename(
        columns={
            "imbalance_up_MW": "cumsum_imbalance_up_MW",
            "imbalance_down_MW": "cumsum_imbalance_down_MW",
        }
    )

    cum_reserve = reserve[["reserve_up_MW", "reserve_down_MW"]].copy()
    cum_reserve[["reserve_up_MW", "reserve_down_MW"]] = (
        cum_reserve
        .groupby(["day"])[["reserve_up_MW", "reserve_down_MW"]]
        .cumsum()
    )
    cum_reserve = cum_reserve.rename(
        columns={
            "reserve_up_MW": "cumsum_reserve_up_MW",
            "reserve_down_MW": "cumsum_reserve_down_MW",
        }
    ).reset_index()

    mu = cum_imbalance.merge(cum_reserve, on=["day", "hour"], how="left")
    mu["mu_up"] = mu["cumsum_imbalance_up_MW"] / mu["cumsum_reserve_up_MW"]
    mu["mu_down"] = mu["cumsum_imbalance_down_MW"] / mu["cumsum_reserve_down_MW"]

    return mu[["day", "hour", "iteration", "mu_up", "mu_down"]]

    # if quantile is None:
    #     return mu

    # mu_q = (
    #     mu
    #     .groupby(["day"])[["mu_up", "mu_down"]]
    #     .quantile(q=quantile)
    #     .rename(columns={"mu_up": "mu_up_q", "mu_down": "mu_down_q"})
    # )
    # mu_q = mu_q.reindex(mu["day"]).reset_index(drop=True)

    # mu = mu.copy()
    # mu["mu_up"] = mu_q["mu_up_q"].to_numpy()
    # mu["mu_down"] = mu_q["mu_down_q"].to_numpy()
    # return mu


def calculate_mu_from_quantiles(mu, quantile):
    return (
        mu
        .groupby(["day", "hour"])[["mu_up", "mu_down"]]
        .quantile(q=quantile)
        .reset_index()
    )


def calculate_mu(demand, random_demand, reserve, quantile=0.975, last=False):
    mu_each = calculate_mu_for_each_imbalance(demand, random_demand, reserve)
    mu_q = calculate_mu_from_quantiles(mu_each, quantile)

    if last:
        last_rows = (
            mu_q.sort_values(["day", "hour"])
            .groupby("day", as_index=False)
            .tail(1)
            .set_index("day")
        )
        mu_q = mu_q.copy()
        mu_q["mu_up"] = mu_q["day"].map(last_rows["mu_up"])
        mu_q["mu_down"] = mu_q["day"].map(last_rows["mu_down"])

    return mu_q

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Estimate reserve multipliers from imbalance quantiles."
    )

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
    parser.add_argument(
        "-q", "--quantile",
        type=float,
        default=0.975,
        help="Quantile used to estimate multipliers (omit to keep all scenarios)",
    )
    args = parser.parse_args()

    demand = pd.read_csv(os.path.join(args.input_folder, "uc", "Demand.csv"))
    random_demand = pd.read_csv(os.path.join(args.input_folder, "ed", "random_demand.csv"))
    reserve = pd.read_csv(os.path.join(args.input_folder, "uc", "Reserve.csv"))

    mu = calculate_mu(demand, random_demand, reserve, quantile=args.quantile, last = True)
    mu_2 = calculate_mu(demand, random_demand, reserve, quantile=args.quantile, last=True)
    mu_2 = mu_2.rename(columns={"mu_up": "mu_2_up", "mu_down": "mu_2_down"})

    mu_1 = calculate_mu(demand, random_demand, reserve, quantile=args.quantile, last=False)
    mu_1 = mu_1.rename(columns={"mu_up": "mu_1_up", "mu_down": "mu_1_down"})

    mu = mu_1.merge(mu_2, on=["day", "hour"])


    mu.to_csv(os.path.join(args.output_folder, "configuration_envelopes_cumulative_reserve_mu.csv"), index=False)

    sys.exit()
