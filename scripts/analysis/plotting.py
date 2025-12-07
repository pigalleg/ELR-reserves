import plotly.graph_objects as go
from plotly.subplots import make_subplots
import pandas as pd
from plotly.subplots import make_subplots as _orig_make_subplots

# Color mapping dictionary
color_map = {
    "battery": "green",
    "Battery": "green",
    "solar_photovoltaic": "gold",
    "net_generation": "goldenrod",
    "onshore_wind_turbine": "skyblue",
    "hydroelectric_pumped_storage": "darkblue",
    "small_hydroelectric": "cornflowerblue",
    "biomass": "#6fc276",
    "natural_gas_fired_combined_cycle": "grey",
    "natural_gas_fired_combustion_turbine": "black",
    "total": "purple",
    "system": "purple",
    "required": "#F0092",
    "envelope_down_MWh": "blue",
    "envelope_up_MWh": "red",
    "reserve_down_MW_eff": "green",
    "reserve_up_MW_eff": "green",
    "SOE_MWh": "rgba(203, 213, 232, 1)",
    "Biomass": "#6fc276",
    "Hydro Pump Storage": "darkblue",
    "CCGT": "grey",
    "OCGT": "black",
    "Onshore Wind": "skyblue",
    "Hydro RoR": "cornflowerblue",
    "Solar": "gold",

    "CSP": "gold",
    "HYDRO": "darkblue",
    "hydro_reservoir": "darkblue",
    "Hydro Reservoir": "darkblue",
    "Hydro dam": "darkblue",
    "ROR": "cornflowerblue",
    "CC": "grey",
    "CT": "black",
    "STEAM": "rgba(36, 121, 108, 1)",
    "NUCLEAR": "rgba(95, 70, 144, 1)",
    "Nuclear": "rgba(95, 70, 144, 1)",
}

def color_discrete_map(key):
    """Get color for a given key, default to red if not found"""
    return color_map.get(key, "red")

def map_stack_group(x, exclude):
    """Map stack group: 1 if not exclude, 2 if exclude"""
    return 1 if x != exclude else 2

TIMESTEP = 'hour'

def plot_fieldx_by_fieldy(df, fieldx, fieldy, title=None):
    """
    Plot fieldx by fieldy with stacked area chart
    
    Parameters:
    -----------
    df : pandas.DataFrame
        Data to plot
    fieldx : str
        Column name for y-axis values
    fieldy : str
        Column name for grouping/legend
    title : str, optional
        Plot title
    """
    fig = go.Figure()
    
    # Get unique values for fieldy
    unique_values = df[fieldy].unique()
    
    for r in unique_values:
        subset = df[df[fieldy] == r]
        fig.add_trace(go.Scatter(
            x=subset[TIMESTEP],
            y=subset[fieldx],
            stackgroup="one",
            mode="lines",
            name=str(r),
            line=dict(width=1, color=color_discrete_map(r), shape="linear")
        ))
    
    fig.update_layout(
        yaxis_title="power MW",
        xaxis_title=TIMESTEP,
        title=title if title else str(fieldx)
    )
    
    return fig

def plot_reserve_by_fieldy(df, fieldx, fieldy, title=None):
    """
    Plot reserve by fieldy with custom stack groups
    
    Parameters:
    -----------
    df : pandas.DataFrame
        Data to plot
    fieldx : str
        Column name for y-axis values
    fieldy : str
        Column name for grouping/legend
    title : str, optional
        Plot title
    """
    fig = go.Figure()
    
    # Get unique values for fieldy
    unique_values = df[fieldy].unique()
    
    for r in unique_values:
        subset = df[df[fieldy] == r]
        stack_group = str(map_stack_group(r, "required"))
        
        fig.add_trace(go.Scatter(
            x=subset[TIMESTEP],
            y=subset[fieldx],
            stackgroup=stack_group,
            mode="lines",
            name=str(r),
            line=dict(width=1, color=color_discrete_map(r), shape="linear")
        ))
    
    fig.update_layout(
        yaxis_title="power MW",
        xaxis_title=TIMESTEP,
        title=title if title else str(fieldx)
    )
    
    return fig

def plot_supply_demand(supply, demand, title=None, column_key=None):
    """
    Plot supply and demand side by side
    
    Parameters:
    -----------
    supply : pandas.DataFrame
        Supply data with 'production_MW' and 'resource' columns
    demand : pandas.DataFrame
        Demand data with 'demand_MW' and 'resource' columns
    title : str, optional
        Overall plot title
    """

    
    def plot_supply_demand_(supply, demand, row, title):
         # Add supply traces
        if not supply.empty:
            unique_resources = supply['resource'].unique()
            for r in unique_resources:
                subset = supply[supply['resource'] == r]
                fig.add_trace(
                    go.Scatter(
                        x=subset[TIMESTEP],
                        y=subset['production_MW'],
                        stackgroup="supply",
                        mode="lines",
                        # name=f"Supply: {r}",
                        name = r,
                        line=dict(width=1, color=color_discrete_map(r), shape="vh"),
                        # legend = "legend"
                        legendgroup="supply",
                        legendgrouptitle_text="Supply"
                        # title = 'hola'
                    ),
                    row=row, col=1
                )
                    # optional per-row annotation/title (keeps behavior similar to plot_supply_demand)
            try:
                # y_max_up = group['reserve_up_MW'].max() if 'reserve_up_MW' in group.columns and not group.empty else 0
                # y_max_down = group['reserve_down_MW'].max() if 'reserve_down_MW' in group.columns and not group.empty else 0
                # y_max = max(float(y_max_up or 0), float(y_max_down or 0))
                if title is not None:
                    axis_index = (row - 1) * 2 + 1  # left column axis index for this row
                    xref_str = "x domain" if axis_index == 1 else f"x{axis_index} domain"
                    yref_str = "y domain" if axis_index == 1 else f"y{axis_index} domain"
                    fig.add_annotation(
                        x=0.01, y=1.05,
                        xref=xref_str, yref=yref_str,
                        text=str(title), showarrow=False
                    )
            except Exception:
                pass

        # Add demand traces
        if not demand.empty:
            unique_resources = demand['resource'].unique()
            for r in unique_resources:
                subset = demand[demand['resource'] == r]
                fig.add_trace(
                    go.Scatter(
                        x=subset[TIMESTEP],
                        y=subset['demand_MW'],
                        stackgroup="demand",
                        mode="lines",
                        # name=f"Demand: {r}",
                        name = r,
                        line=dict(width=1, color=color_discrete_map(r), shape="vh"),
                        # legend = "legend1"
                        legendgroup="demand",
                        legendgrouptitle_text="Demand"
                    ),
                    row=row, col=2
                )
    # Ensure y-axis title appears only on left-hand side axes (for all rows)

    def make_subplots(*args, **kwargs):
        fig = _orig_make_subplots(*args, **kwargs)
        rows = kwargs.get('rows', 1) or 1
        cols = kwargs.get('cols', 1) or 1
        for r in range(1, rows + 1):
            fig.update_yaxes(title_text="[MW]", row=r, col=1)
            for c in range(2, cols + 1):
                fig.update_yaxes(title_text=None, row=r, col=c)
        for c in range(1, cols + 1):
            fig.update_xaxes(title_text=TIMESTEP, row=rows, col=c)
        return fig
    
    # Create subplots
    fig = make_subplots(
        rows=supply[column_key].unique().size if column_key else 1, cols=2,
        subplot_titles=['Supply', 'Demand'],
        shared_yaxes=True,
        shared_xaxes=True
    )
    # tighten spacing between subplots (both horizontally and vertically)
    rows = int(supply[column_key].nunique()) if column_key else 1

    # horizontal spacing (gap between the two columns)
    h_gap = 0.02  # 2% gap
    left_end = 0.5 - h_gap / 2
    right_start = 0.5 + h_gap / 2
    for r in range(1, rows + 1):
        fig.update_xaxes(domain=[0.0, left_end], row=r, col=1)
        fig.update_xaxes(domain=[right_start, 1.0], row=r, col=2)

    # vertical spacing (gap between rows)
    v_gap = 0.03 if rows > 1 else 0.0
    if rows > 1:
        height = (1.0 - v_gap * (rows - 1)) / rows
        bottom = 0.0
        for r in range(1, rows + 1):
            top = bottom + height
            fig.update_yaxes(domain=[bottom, top], row=r, col=1)
            fig.update_yaxes(domain=[bottom, top], row=r, col=2)
            bottom = top + v_gap

    if column_key:
        for i, ((aux, s_group), (_, d_group)) in enumerate(zip(supply.groupby(column_key), demand.groupby(column_key))):
            plot_supply_demand_(s_group, d_group, row=i+1, title=aux)
    else:
        plot_supply_demand_(supply, demand, row=1)

    # Show legend only for traces for the first two plots
    for tr in fig.data:
        xref = getattr(tr, "xaxis", None)
        yref = getattr(tr, "yaxis", None)
        tr.showlegend = (xref in (None, "x", "x2")) # and (yref in (None, "y"))
    
    fig.update_layout(
        title=title,
        # yaxis_title="Reserve (MW)",
        height=max(400, 450 * rows),
        width=1200
    )
    
    return fig

def plot_reserve(reserve, title=None, column_key=None):
    """
    Plot reserve up and down side by side.
    If column_key is provided, create one row per unique value in reserve[column_key].

    Parameters:
    -----------
    reserve : pandas.DataFrame
        Reserve data with 'reserve_up_MW', 'reserve_down_MW' and 'resource' columns
    title : str, optional
        Overall plot title
    column_key : str, optional
        Column name to split rows by (e.g. 'model_type', 'configuration', ...)
    """
    def make_subplots(*args, **kwargs):
        fig = _orig_make_subplots(*args, **kwargs)
        rows = kwargs.get('rows', 1) or 1
        cols = kwargs.get('cols', 1) or 1
        for r in range(1, rows + 1):
            fig.update_yaxes(title_text="[MW]", row=r, col=1)
            for c in range(2, cols + 1):
                fig.update_yaxes(title_text=None, row=r, col=c)
        for c in range(1, cols + 1):
            fig.update_xaxes(title_text=TIMESTEP, row=rows, col=c)
        return fig

    # determine number of rows
    if column_key and (column_key in reserve.columns):
        groups = list(reserve.groupby(column_key))
        n_rows = len(groups)
    else:
        groups = [(None, reserve)]
        n_rows = 1

    # prepare subplot titles: repeat per row
    subplot_titles = []
    for gkey, _ in groups:
        subplot_titles=['Supply', 'Demand']
        subplot_titles.extend([f"Reserve Up ({gkey})" if gkey is not None else "Reserve Up",
                               f"Reserve Down ({gkey})" if gkey is not None else "Reserve Down"])

    fig = make_subplots(
        rows=n_rows, cols=2,
        subplot_titles=['Reserve Up', 'Reserve Down'], #subplot_titles
        shared_yaxes=True,
        shared_xaxes=True
    )

     # tighten spacing between subplots (both horizontally and vertically)
    rows = int(reserve[column_key].nunique()) if column_key else 1

    # horizontal spacing (gap between the two columns)
    h_gap = 0.02  # 2% gap
    left_end = 0.5 - h_gap / 2
    right_start = 0.5 + h_gap / 2
    for r in range(1, rows + 1):
        fig.update_xaxes(domain=[0.0, left_end], row=r, col=1)
        fig.update_xaxes(domain=[right_start, 1.0], row=r, col=2)

    # vertical spacing (gap between rows)
    v_gap = 0.03 if rows > 1 else 0.0
    if rows > 1:
        height = (1.0 - v_gap * (rows - 1)) / rows
        bottom = 0.0
        for r in range(1, rows + 1):
            top = bottom + height
            fig.update_yaxes(domain=[bottom, top], row=r, col=1)
            fig.update_yaxes(domain=[bottom, top], row=r, col=2)
            bottom = top + v_gap


    # iterate groups and add traces to corresponding row
    for i, (gkey, group) in enumerate(groups):
        row = i + 1
        if group is None or group.empty:
            continue

        unique_resources = group['resource'].unique()

        # Add reserve up traces
        for r in unique_resources:
            subset = group[group['resource'] == r]
            stack_group = str(map_stack_group(r, "required"))

            if 'reserve_up_MW' in subset.columns:
                fig.add_trace(
                    go.Scatter(
                        x=subset[TIMESTEP],
                        y=subset['reserve_up_MW'],
                        stackgroup=f"up_{stack_group}_{i}",  # ensure unique stack groups per row
                        mode="lines",
                        # name=f"Up: {r}",
                        name=r,
                        line=dict(width=1, color=color_discrete_map(r),shape="vh"),
                        legendgroup="Up",
                        legendgrouptitle_text="Up",
                        showlegend=(i == 0)  # show legend only for first row to avoid duplicates
                    ),
                    row=row, col=1,
                    
                )

        # Add reserve down traces
        for r in unique_resources:
            subset = group[group['resource'] == r]
            stack_group = str(map_stack_group(r, "required"))

            if 'reserve_down_MW' in subset.columns:
                fig.add_trace(
                    go.Scatter(
                        x=subset[TIMESTEP],
                        y=subset['reserve_down_MW'],
                        stackgroup=f"down_{stack_group}_{i}",
                        mode="lines",
                        # name=f"Down: {r}",
                        name=r,
                        line=dict(width=1, color=color_discrete_map(r),shape="vh"),
                        legendgroup="Down",
                        legendgrouptitle_text="Down",
                        showlegend=(i == 0)  # keep down traces out of legend to avoid duplicates
                    ),
                    row=row, col=2
                )

        # optional per-row annotation/title (keeps behavior similar to plot_supply_demand)
        try:
            # y_max_up = group['reserve_up_MW'].max() if 'reserve_up_MW' in group.columns and not group.empty else 0
            # y_max_down = group['reserve_down_MW'].max() if 'reserve_down_MW' in group.columns and not group.empty else 0
            # y_max = max(float(y_max_up or 0), float(y_max_down or 0))
            if gkey is not None:
                axis_index = (row - 1) * 2 + 1  # left column axis index for this row
                xref_str = "x domain" if axis_index == 1 else f"x{axis_index} domain"
                yref_str = "y domain" if axis_index == 1 else f"y{axis_index} domain"
                fig.add_annotation(
                    x=0.01, y=1.05,
                    xref=xref_str, yref=yref_str,
                    text=str(gkey), showarrow=False
                )
        except Exception:
            pass

    # adjust layout size proportionally to rows
    fig.update_layout(
        title=title,
        # yaxis_title="Reserve (MW)",
        height=max(400, 450 * n_rows),
        width=1200
    )

    return fig

def plot_battery_reserve_(battery_reserve, key):
    """
    Plot battery reserve for a specific key
    
    Parameters:
    -----------
    battery_reserve : pandas.DataFrame
        Battery reserve data
    key : str
        Column name for reserve data (e.g., 'reserve_up_MW_eff')
    """
    fig = go.Figure()
    
    if not battery_reserve.empty:
        # Add SOE trace
        if 'SOE_MWh' in battery_reserve.columns:
            fig.add_trace(go.Scatter(
                x=battery_reserve['hour'],
                y=battery_reserve['SOE_MWh'],
                stackgroup="1",
                mode="lines",
                name="SOE_MWh",
                line=dict(width=1, shape="vh", color=color_discrete_map("SOE_MWh"))
            ))
        
        # Add main key trace
        if key in battery_reserve.columns:
            fig.add_trace(go.Scatter(
                x=battery_reserve['hour'],
                y=battery_reserve[key],
                stackgroup="1",
                mode="lines",
                name=key,
                line=dict(width=1, shape="vh", color=color_discrete_map(key))
            ))
        
        # Add envelope traces if available
        if 'envelope_up_MWh' in battery_reserve.columns:
            fig.add_trace(go.Scatter(
                x=battery_reserve['hour'],
                y=battery_reserve['envelope_up_MWh'],
                mode="lines",
                name="envelope_up_MWh",
                line=dict(width=1, shape="vh", color=color_discrete_map("envelope_up_MWh"))
            ))
        
        if 'envelope_down_MWh' in battery_reserve.columns:
            fig.add_trace(go.Scatter(
                x=battery_reserve['hour'],
                y=battery_reserve['envelope_down_MWh'],
                mode="lines",
                name="envelope_down_MWh",
                line=dict(width=1, shape="vh", color=color_discrete_map("envelope_down_MWh"))
            ))
    
    fig.update_layout(
        yaxis_title="Reserve (MW)",
        xaxis_title="Hour",
        title="All Battery"
    )
    
    return fig

def plot_battery_reserve(battery_reserve):
    """
    Plot battery reserve up and down side by side
    
    Parameters:
    -----------
    battery_reserve : pandas.DataFrame
        Battery reserve data with reserve columns
    """
    # Create subplots
    fig = make_subplots(
        rows=1, cols=2,
        subplot_titles=['Reserve Up Effective', 'Reserve Down Effective'],
        shared_yaxes=True
    )
    
    # Get individual figures for each reserve type
    fig_up = plot_battery_reserve_(battery_reserve, 'reserve_up_MW_eff')
    fig_down = plot_battery_reserve_(battery_reserve, 'reserve_down_MW_eff')
    
    # Add traces from individual figures to subplots
    for trace in fig_up.data:
        fig.add_trace(trace, row=1, col=1)
    
    for trace in fig_down.data:
        # Modify trace to avoid legend duplicates
        trace.showlegend = False
        fig.add_trace(trace, row=1, col=2)
    
    fig.update_layout(
        height=500,
        width=1200,
        title="Battery Reserve Analysis"
    )
    
    return fig

# Additional utility functions for easier use
def plot_commit(commit_uc, commit_ed):
    """
    Plot unit commitment comparison between UC and ED
    """
    fig = make_subplots(
        rows=1, cols=2,
        subplot_titles=['Unit Commitment (UC)', 'Economic Dispatch (ED)'],
        shared_yaxes=True
    )
    
    # Plot UC commitments
    if not commit_uc.empty and 'commit' in commit_uc.columns:
        unique_resources = commit_uc['resource'].unique()
        for r in unique_resources:
            subset = commit_uc[commit_uc['resource'] == r]
            fig.add_trace(
                go.Scatter(
                    x=subset[TIMESTEP] if TIMESTEP in subset.columns else subset.index,
                    y=subset['commit'],
                    mode="lines+markers",
                    name=f"UC: {r}",
                    line=dict(color=color_discrete_map(r))
                ),
                row=1, col=1
            )
    
    # Plot ED commitments
    if not commit_ed.empty and 'commit' in commit_ed.columns:
        unique_resources = commit_ed['resource'].unique()
        for r in unique_resources:
            subset = commit_ed[commit_ed['resource'] == r]
            fig.add_trace(
                go.Scatter(
                    x=subset[TIMESTEP] if TIMESTEP in subset.columns else subset.index,
                    y=subset['commit'],
                    mode="lines+markers",
                    name=f"ED: {r}",
                    line=dict(color=color_discrete_map(r), dash="dash"),
                    showlegend=False
                ),
                row=1, col=2
            )
    
    fig.update_layout(
        title="Unit Commitment Comparison",
        yaxis_title="Commitment",
        height=500,
        width=1200
    )
    
    return fig