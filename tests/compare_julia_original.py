#!/usr/bin/env python3
"""Compare Julia's unchanged CSV outputs with one memory-safe canary run."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import pathlib
import sys


def read_csv(path: pathlib.Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        raise AssertionError(f"{path} is empty")
    return rows[0], rows[1:]


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def compare_csv(
    label: str,
    expected_path: pathlib.Path,
    actual_path: pathlib.Path,
) -> dict[str, object]:
    expected_header, expected_rows = read_csv(expected_path)
    actual_header, actual_rows = read_csv(actual_path)
    report: dict[str, object] = {
        "status": "valid",
        "julia_rows": len(expected_rows),
        "memory_safe_rows": len(actual_rows),
        "julia_columns": len(expected_header),
        "memory_safe_columns": len(actual_header),
        "differing_headers": int(expected_header != actual_header),
        "differing_rows": 0,
        "differing_values": 0,
        "differences_by_column": {},
        "first_differences": [],
        "julia_sha256": sha256(expected_path),
        "memory_safe_sha256": sha256(actual_path),
        "byte_identical": sha256(expected_path) == sha256(actual_path),
    }
    if expected_header != actual_header:
        report["status"] = "invalid"
        report["julia_header"] = expected_header
        report["memory_safe_header"] = actual_header
        return report
    if len(expected_rows) != len(actual_rows):
        report["status"] = "invalid"

    differences_by_column: dict[str, dict[str, object]] = {}
    first_differences: list[dict[str, object]] = []
    differing_rows = 0
    differing_values = 0
    for row_index, (expected, actual) in enumerate(
        zip(expected_rows, actual_rows), start=1
    ):
        if expected != actual:
            differing_rows += 1
            for column, left, right in zip(
                expected_header, expected, actual
            ):
                if left == right:
                    continue
                differing_values += 1
                column_report = differences_by_column.setdefault(
                    column,
                    {"differing_values": 0, "max_absolute_difference": None},
                )
                column_report["differing_values"] = int(
                    column_report["differing_values"]
                ) + 1
                try:
                    absolute_difference = abs(float(left) - float(right))
                    if math.isfinite(absolute_difference):
                        previous = column_report["max_absolute_difference"]
                        if previous is None or absolute_difference > previous:
                            column_report[
                                "max_absolute_difference"
                            ] = absolute_difference
                except ValueError:
                    pass
                if len(first_differences) < 20:
                    first_differences.append(
                        {
                            "row": row_index,
                            "column": column,
                            "julia": left,
                            "memory_safe": right,
                        }
                    )
    report["differing_rows"] = differing_rows
    report["differing_values"] = differing_values
    report["differences_by_column"] = differences_by_column
    report["first_differences"] = first_differences
    if (len(expected_rows) != len(actual_rows) or differing_values > 0):
        report["status"] = "invalid"
    return report


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: compare_julia_original.py DATASET_ID JULIA_OUTPUT_DIR "
            "MEMORY_SAFE_OUTPUT_DIR REPORT_JSON"
        )
    dataset_id = int(sys.argv[1])
    julia_dir = pathlib.Path(sys.argv[2])
    memory_safe_dir = pathlib.Path(sys.argv[3])
    report_path = pathlib.Path(sys.argv[4])

    tile = compare_csv(
        "tile CSV",
        julia_dir / "results.csv",
        memory_safe_dir / f"{dataset_id}_PredInstance_results.csv",
    )
    segment = compare_csv(
        "segment CSV",
        julia_dir / "segment_diagnostics.csv",
        memory_safe_dir
        / f"{dataset_id}_PredInstance_segment_diagnostics.csv",
    )
    if tile["julia_rows"] == 0:
        raise AssertionError("tile CSV contains no AOI tiles")

    valid = tile["status"] == "valid" and segment["status"] == "valid"
    report = {
        "status": "valid" if valid else "invalid",
        "dataset_id": dataset_id,
        "comparison": "zero-tolerance CSV string equality",
        "julia_script_modified": False,
        "tile_csv": tile,
        "segment_csv": segment,
    }
    report_path.write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    if not valid:
        raise SystemExit(
            "Julia/original-LAZ equivalence failed for dataset "
            f"{dataset_id}: tile differences={tile['differing_values']}, "
            f"segment differences={segment['differing_values']}"
        )
    print(
        "Julia/original-LAZ equivalence passed for dataset "
        f"{dataset_id}: {tile['julia_rows']} tiles, "
        f"{segment['julia_rows']} segments, "
        "zero differing values"
    )


if __name__ == "__main__":
    main()
