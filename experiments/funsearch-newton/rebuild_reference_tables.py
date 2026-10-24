#!/usr/bin/env python3
"""Rebuild the plane-curve Newton-polygon reference tables.

The source CSVs are downloaded from Zenodo record 18364679 and checked against
the record's published MD5 checksums before parsing. Raw CSVs stay in a scratch
directory outside the repository. Pass --data-dir to keep and reuse that cache.

The output is one row per distinct polygon at each prime. Array-valued TSV cells
use semicolons; rational entries use exact integer or numerator/denominator
notation. Polygon values are the ordinates at each integer abscissa.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import shutil
import tempfile
from collections import defaultdict
from fractions import Fraction
from pathlib import Path
from urllib.request import Request, urlopen


RECORD_ID = "18364679"
RECORD_URL = f"https://zenodo.org/records/{RECORD_ID}"
INPUTS = {
    5: ("n3_d5_np_rows.csv", "bf5b516ab31f43d531c80353abd70ad6"),
    6: ("n3_d6_np_rows.csv", "25f506379ed179c6f6cc009d408c5d05"),
}
EXPECTED_COUNTS = {
    5: {7: 13, 11: 11, 13: 12, 17: 5, 19: 4, 23: 4},
    6: {7: 9, 11: 8, 13: 7, 17: 7},
}
OUTPUT_NAMES = {
    5: "plane_quintic_newton_polygons.tsv",
    6: "plane_sextic_newton_polygons.tsv",
}

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parent / "reference"


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_source_file(data_dir: Path, filename: str, expected_md5: str) -> Path:
    path = data_dir / filename
    if not path.exists():
        url = f"https://zenodo.org/api/records/{RECORD_ID}/files/{filename}/content"
        request = Request(url, headers={"User-Agent": "NewtonExperiments-reference-rebuilder/1.0"})
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".part", dir=data_dir
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as destination:
                with urlopen(request, timeout=120) as response:
                    shutil.copyfileobj(response, destination)
            actual_md5 = md5(temporary)
            if actual_md5 != expected_md5:
                raise ValueError(
                    f"checksum mismatch for {filename}: expected {expected_md5}, got {actual_md5}"
                )
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    actual_md5 = md5(path)
    if actual_md5 != expected_md5:
        raise ValueError(
            f"checksum mismatch for {path}: expected {expected_md5}, got {actual_md5}"
        )
    return path


def parse_rational_vector(cell: str) -> tuple[Fraction, ...]:
    left = cell.find("[")
    right = cell.rfind("]")
    if left < 0 or right < left:
        raise ValueError(f"not a vector cell: {cell!r}")
    contents = cell[left + 1 : right].strip()
    if not contents:
        return ()
    return tuple(Fraction(token.strip().replace("//", "/")) for token in contents.split(","))


def format_rational(value: Fraction) -> str:
    if value.denominator == 1:
        return str(value.numerator)
    return f"{value.numerator}/{value.denominator}"


def validate_polygon(
    slopes: tuple[Fraction, ...],
    lengths: tuple[int, ...],
    values: tuple[Fraction, ...],
    filename: str,
    row_number: int,
) -> None:
    where = f"{filename}:{row_number}"
    if not slopes or len(slopes) != len(lengths):
        raise ValueError(f"{where}: slopes and lengths must be non-empty parallel vectors")
    if any(left > right for left, right in zip(slopes, slopes[1:])):
        raise ValueError(f"{where}: Newton polygon slopes must be non-decreasing")
    if any(length <= 0 for length in lengths):
        raise ValueError(f"{where}: slope lengths must be positive")
    if len(values) != sum(lengths) + 1:
        raise ValueError(f"{where}: polygon value count does not match the segment lengths")
    if values[0] != 0:
        raise ValueError(f"{where}: the initial polygon ordinate must be zero")

    x = 0
    for slope, length in zip(slopes, lengths):
        for _ in range(length):
            if values[x + 1] - values[x] != slope:
                raise ValueError(f"{where}: polygon values do not follow the listed slopes")
            x += 1


def read_distinct_polygons(path: Path, degree: int) -> dict[int, list[tuple[tuple[Fraction, ...], tuple[int, ...], tuple[Fraction, ...]]]]:
    by_prime: dict[int, list[tuple[tuple[Fraction, ...], tuple[int, ...], tuple[Fraction, ...]]]] = defaultdict(list)
    seen: dict[int, set[tuple[tuple[Fraction, ...], tuple[int, ...], tuple[Fraction, ...]]]] = defaultdict(set)

    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        required = {"n", "d", "p", "slopes", "slopelengths", "values"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise ValueError(f"{path}: missing required columns {sorted(required)}")

        for row_number, row in enumerate(reader, start=2):
            if int(row["n"]) != 3 or int(row["d"]) != degree:
                raise ValueError(f"{path.name}:{row_number}: unexpected n,d values")
            prime = int(row["p"])
            slopes = parse_rational_vector(row["slopes"])
            raw_lengths = parse_rational_vector(row["slopelengths"])
            if any(length.denominator != 1 for length in raw_lengths):
                raise ValueError(f"{path.name}:{row_number}: non-integral slope length")
            lengths = tuple(length.numerator for length in raw_lengths)
            values = parse_rational_vector(row["values"])
            validate_polygon(slopes, lengths, values, path.name, row_number)

            shape = (slopes, lengths, values)
            if shape not in seen[prime]:
                seen[prime].add(shape)
                by_prime[prime].append(shape)

    actual_counts = {prime: len(polygons) for prime, polygons in sorted(by_prime.items())}
    expected_counts = EXPECTED_COUNTS[degree]
    if actual_counts != expected_counts:
        raise ValueError(
            f"{path.name}: distinct polygon counts differ from the pinned record: "
            f"expected {expected_counts}, got {actual_counts}"
        )
    return by_prime


def write_table(path: Path, by_prime: dict[int, list[tuple[tuple[Fraction, ...], tuple[int, ...], tuple[Fraction, ...]]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as destination:
        writer = csv.writer(destination, delimiter="\t", lineterminator="\n")
        writer.writerow(("p", "slopes", "lengths", "polygon_values"))
        for prime in sorted(by_prime):
            for slopes, lengths, values in by_prime[prime]:
                writer.writerow(
                    (
                        prime,
                        ";".join(format_rational(slope) for slope in slopes),
                        ";".join(str(length) for length in lengths),
                        ";".join(format_rational(value) for value in values),
                    )
                )
    temporary.replace(path)


def data_directory(requested: Path | None) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    if requested is None:
        scratch_parent = Path(tempfile.gettempdir()).resolve()
        try:
            scratch_parent.relative_to(REPOSITORY_ROOT)
        except ValueError:
            pass
        else:
            scratch_parent = REPOSITORY_ROOT.parent
        temporary = tempfile.TemporaryDirectory(
            prefix="newton-polygon-reference-", dir=scratch_parent
        )
        return Path(temporary.name), temporary

    resolved = requested.expanduser().resolve()
    try:
        resolved.relative_to(REPOSITORY_ROOT)
    except ValueError:
        pass
    else:
        raise ValueError(f"raw Zenodo data must stay outside the repository: {resolved}")
    resolved.mkdir(parents=True, exist_ok=True)
    return resolved, None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-dir",
        type=Path,
        help="scratch directory for the downloaded source CSVs (must be outside the repository)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"directory for generated tables (default: {DEFAULT_OUTPUT_DIR})",
    )
    args = parser.parse_args()

    scratch_dir, temporary = data_directory(args.data_dir)
    try:
        tables = {}
        for degree, (filename, checksum) in INPUTS.items():
            source = verified_source_file(scratch_dir, filename, checksum)
            print(f"verified {source} (md5:{checksum})")
            tables[degree] = read_distinct_polygons(source, degree)

        # Validate and stage every table before replacing either committed output.
        args.output_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".newton-reference-tables-", dir=args.output_dir
        ) as staging_name:
            staging_dir = Path(staging_name)
            staged_outputs: list[tuple[Path, Path]] = []
            for degree, polygons in tables.items():
                output = args.output_dir / OUTPUT_NAMES[degree]
                staged_output = staging_dir / output.name
                write_table(staged_output, polygons)
                staged_outputs.append((staged_output, output))

            backups: dict[Path, Path | None] = {}
            for _, output in staged_outputs:
                if output.is_symlink():
                    backup = staging_dir / f"{output.name}.backup"
                    backup.symlink_to(os.readlink(output))
                    backups[output] = backup
                elif output.exists():
                    backup = staging_dir / f"{output.name}.backup"
                    shutil.copy2(output, backup)
                    backups[output] = backup
                else:
                    backups[output] = None

            published: list[Path] = []
            try:
                for staged_output, output in staged_outputs:
                    staged_output.replace(output)
                    published.append(output)
            except BaseException as publish_error:
                rollback_errors = []
                for output in reversed(published):
                    backup = backups[output]
                    try:
                        if backup is None:
                            output.unlink(missing_ok=True)
                        else:
                            backup.replace(output)
                    except OSError as rollback_error:
                        rollback_errors.append((output, rollback_error))

                if rollback_errors:
                    details = "; ".join(
                        f"{output}: {error}" for output, error in rollback_errors
                    )
                    raise RuntimeError(
                        f"table publication failed ({publish_error}); rollback also failed: {details}"
                    ) from rollback_errors[0][1]
                raise

        for degree, polygons in tables.items():
            output = args.output_dir / OUTPUT_NAMES[degree]
            counts = ", ".join(f"p={prime}: {len(rows)}" for prime, rows in sorted(polygons.items()))
            print(f"wrote {output} ({counts})")
        print(f"source: {RECORD_URL}")
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    main()
