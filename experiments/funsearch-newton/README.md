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
  --data-dir /tmp/newton-polygon-source
```

The script verifies the source checksums and asserts the pinned distinct-polygon
counts before writing either table.

Run the offline Python tests from the repository root with:

```sh
python3 -m unittest discover -s test -p 'test_*.py'
```
