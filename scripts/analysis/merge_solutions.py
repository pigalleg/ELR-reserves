from processing import filter_demand, transform_to_internal_time, load_solutions, combine_solutions
import os
import pandas as pd

read_files = False
write_files = True
# solution_keys = ['dual_variables', 'storage']
solution_keys = ['reserve']

if not read_files:
    ss = [
        # {'solution_folder': f"RTS-GMLC_v18.3s", 'model_type' : 'envelope'},
        # {'solution_folder': f"RTS-GMLC_v19.4s", 'model_type' : 'e-reserve'},
        {'solution_folder': f"RTS-GMLC_v32.3s", 'model_type' : 'envelope'},
        {'solution_folder': f"RTS-GMLC_v32.1s", 'model_type' : 'e-reserve'},
    ]
    days = range(1,365)
    s_uc = []
    s_ed = []
    gcd_KPI_adequacy = []
    gcdi_KPI_adequacy = []
    

    for sol in ss:
        # ρ = sol['ρ']
        s = sol['solution_folder']
        # s_uc_name = 's_uc' if sol['model_type'] == 'stochastic' else 's_uc'
        # s_ed_name = 's_sed'
        s_uc_ = load_solutions("s_uc", os.path.join("..","..", "output", s), days, solution_keys = solution_keys,  model_type = sol['model_type'], solution_id = s)
        if sol['model_type'] != 'stochastic':
            s_ed_ = load_solutions("s_ed", os.path.join("..","..", "output", s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
        else:
            s_ed_ = load_solutions("s_suc", os.path.join("..","..", "output", s), days, solution_keys = solution_keys, model_type = sol['model_type'], solution_id = s)
        s_uc.append(s_uc_)
        s_ed.append(s_ed_)

        # gcd_KPI_adequacy_ = read_parquet_and_convert( os.path.join("..", "output", s, "all_gcd_KPI_adequacy.parquet"))
        # gcd_KPI_adequacy_ = add_fields(gcd_KPI_adequacy_, model_type = sol['model_type'], ρ=ρ, solution_id = s) 

        # gcdi_KPI_adequacy_ = read_parquet_and_convert( os.path.join("..", "output", s, "all_gcdi_KPI_adequacy.parquet"))
        # gcdi_KPI_adequacy_ = add_fields(gcdi_KPI_adequacy_, model_type = sol['model_type'], ρ=ρ, solution_id = s)

        # gcd_KPI_adequacy.append(gcd_KPI_adequacy_)
        # gcdi_KPI_adequacy.append(gcdi_KPI_adequacy_)

    s_uc = combine_solutions(s_uc)
    s_ed = combine_solutions(s_ed)
    # gcd_KPI_adequacy = pd.concat(gcd_KPI_adequacy)
    # gcdi_KPI_adequacy = pd.concat(gcdi_KPI_adequacy)

    for k,v in s_uc.items():
        if 'µ' in v.columns:
            s_uc[k]['model_type'] =  v.apply(lambda x: 'conservative' if (x['model_type'] == 'envelope') & (x['µ'] == 1) else x['model_type'], axis=1)
    for k,v in s_ed.items():
        if 'µ' in v.columns:
            s_ed[k]['model_type'] = v.apply(lambda x: 'conservative' if (x['model_type'] == 'envelope') & (x['µ'] == 1) else x['model_type'], axis=1)
    # if 'µ' in gcdi_KPI_adequacy.columns: 
    #     gcdi_KPI_adequacy['model_type'] = gcdi_KPI_adequacy.apply(lambda x: 'conservative' if (x['model_type'] == 'envelope') & (x['µ'] == 1) else x['model_type'], axis=1)
    #     gcd_KPI_adequacy['model_type'] = gcd_KPI_adequacy.apply(lambda x: 'conservative' if (x['model_type'] == 'envelope') & (x['µ'] == 1) else x['model_type'], axis=1)
    if write_files:
        for k,v in s_uc.items():
            v.to_csv(f's_uc_{k}.csv', index=False)
        for k,v in s_ed.items():
            v.to_csv(f's_ed_{k}.csv', index=False)

else:
    s_uc = {}
    s_ed = {}
    for solution_key in solution_keys:
        s_uc[solution_key] = pd.read_csv(f's_uc_{solution_key}.csv')
        s_ed[solution_key] = pd.read_csv(f's_ed_{solution_key}.csv')    

    # gcd_KPI_adequacy = pd.read_csv('gcd_KPI_adequacy.csv', index_col=0)
    # gcdi_KPI_adequacy = pd.read_csv('gcdi_KPI_adequacy.csv', index_col=0)





