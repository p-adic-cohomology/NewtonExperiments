from __future__ import annotations

import csv
import hashlib
import io
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

    def test_validate_polygon_rejects_malformed_vectors(self) -> None:
        cases = (
            ((), (), (Fraction(0),), "non-empty parallel vectors"),
            ((Fraction(0),), (), (Fraction(0),), "non-empty parallel vectors"),
            ((Fraction(0),), (0,), (Fraction(0),), "must be positive"),
            ((Fraction(0),), (1,), (Fraction(1), Fraction(1)), "initial polygon ordinate"),
        )
        for slopes, lengths, values, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    rebuild.validate_polygon(slopes, lengths, values, "fixture.csv", 2)

    def test_read_distinct_polygons_rejects_non_integral_slope_lengths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.csv"
            with source.open("w", newline="", encoding="utf-8") as output:
                writer = csv.writer(output)
                writer.writerow(("n", "d", "p", "slopes", "slopelengths", "values"))
                writer.writerow((3, 5, 7, "[1/2]", "[1/2]", "[0,1/2]"))

            with self.assertRaisesRegex(ValueError, "non-integral slope length"):
                rebuild.read_distinct_polygons(source, 5)

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

    def test_data_directory_rejects_repository_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / "repository"
            repository.mkdir()
            repository = repository.resolve()
            with patch.object(rebuild, "REPOSITORY_ROOT", repository):
                with self.assertRaisesRegex(ValueError, "must stay outside the repository"):
                    rebuild.data_directory(repository / "cache")

    def test_default_data_directory_stays_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            repository = repository.resolve()
            configured_temp = repository / "configured-temp"
            configured_temp.mkdir()

            with (
                patch.object(rebuild, "REPOSITORY_ROOT", repository),
                patch.object(rebuild.tempfile, "gettempdir", return_value=str(configured_temp)),
            ):
                scratch, temporary = rebuild.data_directory(None)

            try:
                with self.assertRaises(ValueError):
                    scratch.resolve().relative_to(repository.resolve())
            finally:
                self.assertIsNotNone(temporary)
                temporary.cleanup()

    def test_uncached_source_download_verifies_and_cleans_partial_files(self) -> None:
        payload = b"downloaded source contents"
        expected = hashlib.md5(payload).hexdigest()
        url = (
            f"https://zenodo.org/api/records/{rebuild.RECORD_ID}/"
            "files/source.csv/content"
        )

        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            with patch.object(rebuild, "urlopen", return_value=io.BytesIO(payload)) as open_url:
                source = rebuild.verified_source_file(data_dir, "source.csv", expected)

            self.assertEqual(source.read_bytes(), payload)
            self.assertEqual(open_url.call_args.args[0].full_url, url)
            self.assertFalse((data_dir / "source.csv.part").exists())

        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            with patch.object(rebuild, "urlopen", return_value=io.BytesIO(payload)):
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    rebuild.verified_source_file(data_dir, "source.csv", "0" * 32)

            self.assertFalse((data_dir / "source.csv").exists())
            self.assertFalse((data_dir / "source.csv.part").exists())
            self.assertEqual(list(data_dir.glob(".source.csv.*.part")), [])

    def test_uncached_download_does_not_follow_preexisting_partial_symlink(self) -> None:
        payload = b"downloaded source contents"
        expected = hashlib.md5(payload).hexdigest()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data_dir = root / "cache"
            data_dir.mkdir()
            target = root / "sentinel.txt"
            target.write_bytes(b"keep this file unchanged")
            partial = data_dir / "source.csv.part"
            partial.symlink_to(target)

            with patch.object(rebuild, "urlopen", return_value=io.BytesIO(payload)):
                source = rebuild.verified_source_file(data_dir, "source.csv", expected)

            self.assertEqual(source.read_bytes(), payload)
            self.assertTrue(partial.is_symlink())
            self.assertEqual(target.read_bytes(), b"keep this file unchanged")
            self.assertEqual(list(data_dir.glob(".source.csv.*.part")), [])

    def test_main_validates_all_sources_before_replacing_any_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data_dir = root / "cache"
            output_dir = root / "reference"
            output_dir.mkdir()
            quintic = output_dir / rebuild.OUTPUT_NAMES[5]
            sextic = output_dir / rebuild.OUTPUT_NAMES[6]
            quintic.write_bytes(b"old quintic table")
            sextic.write_bytes(b"old sextic table")

            def read_polygons(source: Path, degree: int):
                if degree == 6:
                    raise ValueError("sextic validation failed")
                return {7: []}

            argv = [
                "rebuild_reference_tables.py",
                "--data-dir",
                str(data_dir),
                "--output-dir",
                str(output_dir),
            ]
            with (
                patch("sys.argv", argv),
                patch.object(
                    rebuild,
                    "verified_source_file",
                    side_effect=lambda directory, filename, _checksum: directory / filename,
                ),
                patch.object(rebuild, "read_distinct_polygons", side_effect=read_polygons),
            ):
                with self.assertRaisesRegex(ValueError, "sextic validation failed"):
                    rebuild.main()

            self.assertEqual(quintic.read_bytes(), b"old quintic table")
            self.assertEqual(sextic.read_bytes(), b"old sextic table")

    def test_main_rolls_back_pair_if_second_output_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data_dir = root / "cache"
            output_dir = root / "reference"
            output_dir.mkdir()
            quintic = output_dir / rebuild.OUTPUT_NAMES[5]
            sextic = output_dir / rebuild.OUTPUT_NAMES[6]
            quintic.write_bytes(b"old quintic table")
            sextic.write_bytes(b"old sextic table")

            argv = [
                "rebuild_reference_tables.py",
                "--data-dir",
                str(data_dir),
                "--output-dir",
                str(output_dir),
            ]
            original_replace = Path.replace

            def fail_sextic_replace(source: Path, target: str | Path) -> Path:
                if Path(target) == sextic:
                    raise OSError("sextic publication failed")
                return original_replace(source, target)

            with (
                patch("sys.argv", argv),
                patch.object(
                    rebuild,
                    "verified_source_file",
                    side_effect=lambda directory, filename, _checksum: directory / filename,
                ),
                patch.object(rebuild, "read_distinct_polygons", return_value={7: []}),
                patch.object(Path, "replace", fail_sextic_replace),
            ):
                with self.assertRaisesRegex(OSError, "sextic publication failed"):
                    rebuild.main()

            self.assertEqual(quintic.read_bytes(), b"old quintic table")
            self.assertEqual(sextic.read_bytes(), b"old sextic table")

    def test_committed_reference_tables_match_pinned_content(self) -> None:
        expected_hashes = {
            5: "b14f1d0fa945454f874dbcb58aa2b2e908af3915c40f0ec31bcc3cd3f62fbce5",
            6: "98f8821c081e61a8a7e6f063debcedae4dd967eefa0c03908ffbf08f9d48b20c",
        }
        for degree, filename in rebuild.OUTPUT_NAMES.items():
            with self.subTest(degree=degree):
                path = rebuild.DEFAULT_OUTPUT_DIR / filename
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(digest, expected_hashes[degree])
                with path.open(newline="", encoding="utf-8") as source:
                    rows = list(csv.reader(source, delimiter="\t"))
                self.assertEqual(rows[0], ["p", "slopes", "lengths", "polygon_values"])
                counts: dict[int, int] = {}
                for row in rows[1:]:
                    prime = int(row[0])
                    counts[prime] = counts.get(prime, 0) + 1
                self.assertEqual(counts, rebuild.EXPECTED_COUNTS[degree])

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
