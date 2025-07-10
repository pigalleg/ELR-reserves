using PlotlyJS
# using XLSX
include("./model/utils.jl")
# include("../model/unit_commitment.jl")
# include("../model/economic_dispatch.jl")
include("./notebooks/plotting.jl")
include("./notebooks//processing.jl")


folder_path = joinpath(".","output", "solutions_v10.5u")
solution_folders = ["n_7", "n_38", "n_259", "n_289"]
# solution_folders = ["n_38"]

keys = [:demand, :generation, :storage, :reserve, :energy_reserve, :scalar]
s_uc = [parquet_to_solution("s_uc", joinpath(folder_path, s)) for s in solution_folders]
s_ed = [parquet_to_solution("s_ed", joinpath(folder_path, s)) for s in solution_folders]
s_uc = NamedTuple(k => vcat([s[k] for s in s_uc if haskey(s, k)]...) for k in keys)
s_ed = NamedTuple(k => vcat([s[k] for s in s_ed if haskey(s, k)]...) for k in keys)
;

aux = "all"
# aux = join(string.("n_",[7, 228, 259, 289]),"_")
gcdi_KPI_adequacy = read_parquet_and_convert(joinpath(folder_path,"$(aux)_gcdi_KPI_adequacy.parquet"))
gcd_KPI_adequacy = read_parquet_and_convert(joinpath(folder_path,"$(aux)_gcd_KPI_adequacy.parquet"))
KPI_reserve = read_parquet_and_convert(joinpath(folder_path,"$(aux)_KPI_reserve.parquet"))
gcdi_KPI_reserve = read_parquet_and_convert(joinpath(folder_path,"$(aux)_gcdi_KPI_reserve.parquet"))
gcd_KPI_reserve = read_parquet_and_convert(joinpath(folder_path,"$(aux)_gcd_KPI_reserve.parquet"))
;


s_uc_scalar = rename(unique(gcdi_KPI_adequacy[!,[:configuration,:day,:objective_value_uc]]), :objective_value_uc => :objective_value)
s_uc_scalar = include_Δobjective_value(s_uc_scalar, [:day])
s_uc_scalar.Δobjective_value_relative_percentage_conf .= 100*s_uc_scalar.Δobjective_value_relative_ref_conf
transform!(s_uc_scalar, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu)
sort!(s_uc_scalar, :mu)


tolerance = 0.001 #1 Watt
group_by = [:configuration, :day, :hour]
required_reserve =leftjoin(
        s_ed.demand[!,union(group_by,[:iteration, :demand_MW, :LOL_MW, :LGEN_MW])],
        rename(s_uc.demand[!, union(group_by,[:demand_MW])], :demand_MW => :demand_uc_MW),
        on = group_by
    )
required_reserve.required_r_MW =  (required_reserve.demand_MW .+ required_reserve.LOL_MW .- required_reserve.demand_uc_MW)
required_reserve.required_r_relative = required_reserve.required_r_MW ./ required_reserve.demand_uc_MW
required_reserve.redispatch_MW = required_reserve.LOL_MW - required_reserve.LGEN_MW  #- required_reserve.curtailment_MW
required_reserve.redispatch_needed = abs.(required_reserve.redispatch_MW).>=tolerance
required_reserve = sort(transform(required_reserve, :configuration .=> ByRow(x -> parse_configuration_to_mu(x)) .=> :mu), :mu)