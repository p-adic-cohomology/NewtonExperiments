from __future__ import annotations

import csv
import hashlib
import importlib.util
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path
from unittest.mock import patch


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "experiments"
    / "funsearch-newton"
    / "rebuild_reference_tables.py"
)
SPEC = importlib.util.spec_from_file_location("rebuild_reference_tables", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT_PATH}")
rebuild = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rebuild)


class ReferenceTableTests(unittest.TestCase):
    def test_parse_rational_vector_is_exact_and_requires_brackets(self) -> None:
        self.assertEqual(
            rebuild.parse_rational_vector("[1//2, -3, 4/5]"),
            (Fraction(1, 2), Fraction(-3), Fraction(4, 5)),
        )
        with self.assertRaises(ValueError):
            rebuild.parse_rational_vector("1, 2")

    def test_validate_polygon_checks_slopes_and_value_count(self) -> None:
        rebuild.validate_polygon(
            (Fraction(0), Fraction(1)),
            (1, 1),
            (Fraction(0), Fraction(0), Fraction(1)),
            "fixture.csv",
            2,
        )
        with self.assertRaisesRegex(ValueError, "do not follow"):
            rebuild.validate_polygon(
                (Fraction(0), Fraction(1)),
                (1, 1),
                (Fraction(0), Fraction(0), Fraction(2)),
                "fixture.csv",
                2,
            )
        with self.assertRaisesRegex(ValueError, "value count"):
            rebuild.validate_polygon(
                (Fraction(0), Fraction(1)),
                (1, 1),
                (Fraction(0), Fraction(1)),
                "fixture.csv",
                2,
            )

    def test_read_distinct_polygons_deduplicates_and_checks_pinned_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.csv"
            with source.open("w", newline="", encoding="utf-8") as output:
                writer = csv.writer(output)
                writer.writerow(("n", "d", "p", "slopes", "slopelengths", "values"))
                row = (3, 5, 7, "[0,1]", "[1,1]", "[0,0,1]")
                writer.writerow(row)
                writer.writerow(row)

            with patch.dict(rebuild.EXPECTED_COUNTS, {5: {7: 1}}):
                polygons = rebuild.read_distinct_polygons(source, 5)
            self.assertEqual(len(polygons[7]), 1)

            with patch.dict(rebuild.EXPECTED_COUNTS, {5: {7: 2}}):
                with self.assertRaisesRegex(ValueError, "counts differ"):
                    rebuild.read_distinct_polygons(source, 5)

    def test_cached_source_checksum_is_verified(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "cached.csv"
            source.write_bytes(b"trusted contents")
            expected = hashlib.md5(source.read_bytes()).hexdigest()
            self.assertEqual(
                rebuild.verified_source_file(Path(directory), source.name, expected),
                source,
            )
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                rebuild.verified_source_file(Path(directory), source.name, "0" * 32)

    def test_write_table_sorts_primes_and_preserves_exact_rational_format(self) -> None:
        polygons = {
            13: [
                (
                    (Fraction(1, 2), Fraction(2)),
                    (2, 1),
                    (Fraction(0), Fraction(1, 2), Fraction(1), Fraction(3)),
                )
            ],
            7: [
                (
                    (Fraction(-1, 3),),
                    (1,),
                    (Fraction(0), Fraction(-1, 3)),
                )
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested" / "references.tsv"
            rebuild.write_table(output, polygons)
            with output.open(newline="", encoding="utf-8") as source:
                rows = list(csv.reader(source, delimiter="\t"))

        self.assertEqual(
            rows,
            [
                ["p", "slopes", "lengths", "polygon_values"],
                ["7", "-1/3", "1", "0;-1/3"],
                ["13", "1/2;2", "2;1", "0;1/2;1;3"],
            ],
        )


if __name__ == "__main__":
    unittest.main()
