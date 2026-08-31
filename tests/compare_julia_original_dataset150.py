#!/usr/bin/env python3
"""Compare the unchanged Julia script and memory-safe dataset-150 CSVs."""

from __future__ import annotations

import csv
import json
import pathlib
import sys


def read_csv(path: pathlib.Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    if not rows:
        raise AssertionError(f"{path} is empty")
    return rows[0], rows[1:]


def assert_identical(
    label: str,
    expected_path: pathlib.Path,
    actual_path: pathlib.Path,
    expected_rows: int,
) -> None:
    expected_header, expected = read_csv(expected_path)
    actual_header, actual = read_csv(actual_path)
    if expected_header != actual_header:
        raise AssertionError(f"{label} header differs")
    if len(expected) != expected_rows or len(actual) != expected_rows:
        raise AssertionError(
            f"{label} expected {expected_rows} rows; "
            f"Julia={len(expected)}, memory-safe={len(actual)}"
        )
    for row_index, (left, right) in enumerate(zip(expected, actual), start=1):
        if left != right:
            differences = [
                f"{column}: {a!r} != {b!r}"
                for column, a, b in zip(expected_header, left, right)
                if a != b
            ]
            raise AssertionError(
                f"{label} row {row_index} differs: "
                + "; ".join(differences[:12])
            )


def main() -> None:
    if len(sys.argv) not in (4, 6):
        raise SystemExit(
            "usage: compare_julia_original_dataset150.py "
            "JULIA_OUTPUT_DIR MEMORY_SAFE_OUTPUT_DIR REPORT_JSON "
            "[EXPECTED_TILE_ROWS EXPECTED_SEGMENT_ROWS]"
        )
    julia_dir = pathlib.Path(sys.argv[1])
    memory_safe_dir = pathlib.Path(sys.argv[2])
    report_path = pathlib.Path(sys.argv[3])
    expected_tile_rows = int(sys.argv[4]) if len(sys.argv) == 6 else 147
    expected_segment_rows = int(sys.argv[5]) if len(sys.argv) == 6 else 397

    assert_identical(
        "tile CSV",
        julia_dir / "results.csv",
        memory_safe_dir / "150_PredInstance_results.csv",
        expected_tile_rows,
    )
    assert_identical(
        "segment CSV",
        julia_dir / "segment_diagnostics.csv",
        memory_safe_dir / "150_PredInstance_segment_diagnostics.csv",
        expected_segment_rows,
    )
    report = {
        "status": "valid",
        "comparison": "zero-tolerance string equality",
        "julia_script_modified": False,
        "tile_rows": expected_tile_rows,
        "segment_rows": expected_segment_rows,
        "differing_headers": 0,
        "differing_rows": 0,
        "differing_values": 0,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "Julia/original-LAZ equivalence passed: "
        f"{expected_tile_rows} tiles, {expected_segment_rows} segments, "
        "zero differing values"
    )


if __name__ == "__main__":
    main()
