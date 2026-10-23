# NewtonExperiments.jl

[![CI](https://github.com/UCSD-computational-number-theory/NewtonExperiments.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/UCSD-computational-number-theory/NewtonExperiments.jl/actions/workflows/CI.yml)

This repository contains experiment scripts for computing zeta functions and Newton polygons using [DeRham.jl](https://github.com/UCSD-computational-number-theory/DeRham.jl).

**This package is work-in-progress.** It may have rough edges. PRs and contributions are welcome.

## Getting Started

#### Installing for the first time

First, install Julia 1.12 and Oscar. If you're new to Julia and Oscar, you can find a tutorial for non-experts [here](https://jjgarzella.github.io/blog/how-to-install-julia/). In short:

* On Windows, install Ubuntu through WSL and use the Ubuntu terminal.
* On Mac, open Terminal and run `xcode-select --install`.
* On Linux, open your usual terminal.

Then install Julia with `curl -fsSL https://install.julialang.org | sh`, restart your terminal if necessary, open a Julia REPL with `julia`, press `]` to enter package mode, and run `add Oscar`. Press backspace to return to the Julia prompt and check that `using Oscar` works.

If you'd like to use CUDA, you'll need to install the CUDA driver, see [the instructions in the CUDA.jl docs](https://cuda.juliagpu.org/stable/installation/overview/).

You should have CUDA and Julia installed, and you should have `GPUFiniteFieldMatrices.jl`, `DeRham.jl`, and this repository cloned next to one another:

```
git clone https://github.com/UCSD-computational-number-theory/GPUFiniteFieldMatrices.jl.git
git clone https://github.com/UCSD-computational-number-theory/DeRham.jl.git
git clone https://github.com/UCSD-computational-number-theory/NewtonExperiments.jl.git
```

The first time you install NewtonExperiments.jl, it will take a while for Julia to download and compile all of the dependencies. To do this, make sure your Julia REPL is in the NewtonExperiments.jl project folder. Then, in the package prompt, run

```
activate .
```

Then, press backspace to go back to a julia prompt and run

```julia
include("scripts/setup_deps.jl")
```

This script locates the sibling checkouts next to the main NewtonExperiments repository, including when NewtonExperiments is opened through a Git worktree. It uses `Pkg.develop` with a path relative to the active checkout, then instantiates the project; the generated `Project.toml` and `Manifest.toml` therefore contain relative paths rather than a developer-specific absolute path. The tracked manifest uses paths relative to the main checkout, and running this script from a linked worktree rewrites them relative to that worktree. If the sibling repositories are stored elsewhere, set `NEWTON_SIBLING_ROOT` to their containing directory before running the script. The script clones either sibling from its GitHub repository if it is missing.

`Revise.jl` is recommended for hot reloading. From a new Julia REPL, run `using Pkg; Pkg.add("Revise")` once, and then run `using Revise` upon opening every new REPL.

#### Starting a new session after installation is complete

After starting a new Julia REPL, run

```
using Revise
] activate .
```

Then, press backspace to go back to a julia prompt and run

```julia
using NewtonExperiments, DeRham, Oscar
```

## Running Experiments

#### Local experiments

Execute the following lines in a Julia REPL:

```julia
using NewtonExperiments

df = empty_results_dataframe()
df = run_experiment(:cpu_vector_fast_random, 3, 3, 5, 1, df)
```

If CUDA is available, you may also launch experiments using the GPU:

```julia
using NewtonExperiments

df = empty_results_dataframe()
df = run_experiment(:gpu_random_cubic_fourfold, 6, 3, 13, 1, df)
```

#### Supabase experiments

Set your Supabase credentials in the shell:

```
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_KEY="your-supabase-key"
```

Then run the default GPU random hypersurface pipeline:

```
julia --project=. scripts/run_supabase_pipeline.jl
```

The script fetches the existing table, runs the selected experiment, writes the full table to CSV, and pushes only new rows back to Supabase.

You can configure the experiment from environment variables:

```
NEWTON_N=6 \
NEWTON_D=3 \
NEWTON_P=13 \
NEWTON_SAMPLES=1 \
NEWTON_EXPERIMENT=gpu_random_hypersurface \
julia --project=. scripts/run_supabase_pipeline.jl
```

Alternatively, you may pass these parameters into the function `run_supabase_pipeline()`.

## Running Tests

From the NewtonExperiments.jl project folder, first set up the unregistered dependencies:

```
julia --project=. scripts/setup_deps.jl
```

Then run the test suite:

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

The tests run small local examples and do not push to Supabase.

## Citing Our Work

You are welcome to use the code in this repository for your own research, but we ask that you please cite our paper [Newton strata realization for hypersurfaces via explicit p-adic cohomology](https://arxiv.org/abs/2602.24155) (by Ryan Batubara, Jack J Garzella, Yongyuan Huang, and Maximus Mellberg, arxiv:2602.24155 (2026)) if and when you publish your results.

## License

NewtonExperiments.jl is distributed under the GNU General Public License, version 2.
