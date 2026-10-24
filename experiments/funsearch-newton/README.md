# FunSearch Newton polygon references

The reference tables contain distinct Newton polygons from the plane-curve rows
in [Zenodo record 18364679](https://doi.org/10.5281/zenodo.18364679). The raw CSV
files are not committed. The rebuild script downloads the quintic and sextic
CSVs to scratch space outside the repository and checks their published MD5
checksums before extracting the tables.

Each TSV row represents one distinct polygon for a prime. The columns are the
prime `p`, its ordered `slopes`, the corresponding horizontal `lengths`, and
`polygon_values`, the exact ordinate at each integer abscissa. Vector entries
are separated by semicolons; non-integral rationals use `numerator/denominator`
notation. The quintic table includes all six requested primes and has distinct
polygon counts 13, 11, 12, 5, 4, and 4 for p = 7, 11, 13, 17, 19, and 23. The
sextic table includes all primes represented in the source CSV.

Rebuild the tables, downloading the source files into a temporary scratch
directory:

```sh
python3 experiments/funsearch-newton/rebuild_reference_tables.py
```

To retain and reuse the downloaded source files, pass a scratch directory outside
the repository:

```sh
python3 experiments/funsearch-newton/rebuild_reference_tables.py \
  --data-dir /tmp/newton-polygon-source \
  --output-dir /tmp/newton-polygon-reference
```

Generated tables go to `experiments/funsearch-newton/reference` by default;
`--output-dir` selects a different destination for them.

The script verifies both source checksums and pinned distinct-polygon counts, then
stages both tables before replacing either output. A failed download or
validation leaves the existing tables unchanged.

Run the offline Python tests from the repository root with:

```sh
python3 -m unittest discover -s test -p 'test_*.py'
```

## FunSearch problem

The plane-quintic problem lives in this directory. Its neutral candidate
contract, default seed, C worker evaluator, and run configuration are in
problem.md, candidate.h, seed.c, and problem.toml. Alternative seeds are under
seeds/; copy the selected file to seed.c before a check or run.

Use the managed launcher to check the configured seed against the resident
server without starting a search:

~~~sh
experiments/funsearch-newton/server/run_funsearch.sh check \
  experiments/funsearch-newton \
  --instance 'family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true'
~~~

The launcher also has a run mode for an explicitly authorized FunSearch run.
It waits for server readiness, retains the server's ready record and curve log
under the run directory, and stops the server when the run finishes. See
server/README.md for launcher variables and run options.
