module NewtonExperiments

using CSV
using Combinatorics
using DataFrames
using DeRham
using Distributed
using HTTP
using JSON
using Oscar
using Random

include("NewtonStrata.jl")

export NewtonStrata
export SupabaseClient
export headers, push_row, fetch_table, add_heights_patch!
export empty_results_dataframe, update_results!, update_df
export derham_S, gpu_derham_S
export find_0smooth, find_nsmooth
export cpu_example_fast_random, cpu_vector_fast_random, cpu_vector_fast_random_K3
export cpu_smooth_distributed, gpu_smooth_distributed
export all_monomials, random_monomial
export cpu_example_fast_example, cpu_vector_fast_example, cpu_vector_fast_weighted_example
export partitions_leq, monomial_symmetric_polynomial, all_monomial_symmetric_polynomials
export all_tuples_of_length, cpu_vector_fast_symmetric
export gpu_random_hypersurface_experiment, gpu_random_cubic_fourfold_experiment
export data_fermat_curves, data_fermat_deform_6
export run_experiment, run_supabase_pipeline

include("Supabase.jl")
include("Results.jl")
include("CubicFourfolds.jl")
include("CPUExperiments.jl")
include("GPUExperiments.jl")
include("ZetaData.jl")
include("Pipeline.jl")

end
