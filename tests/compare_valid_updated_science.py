#!/usr/bin/env python3
"""Compare ForestStructure science outputs with a valid_updated oracle."""

from __future__ import annotations

import csv
import json
import pathlib
import sys
from typing import Any


IGNORED_METADATA_FIELDS = {"file"}


def normalized_csv(path: pathlib.Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        raise AssertionError(f"{path} is empty")
    keep = [
        index
        for index, name in enumerate(rows[0])
        if name not in IGNORED_METADATA_FIELDS
    ]
    return (
        [rows[0][index] for index in keep],
        [[row[index] for index in keep] for row in rows[1:]],
    )


def compare_csv(expected: pathlib.Path, actual: pathlib.Path) -> dict[str, Any]:
    expected_header, expected_rows = normalized_csv(expected)
    actual_header, actual_rows = normalized_csv(actual)
    first_differences: list[dict[str, Any]] = []
    differing_values = 0
    for row_index, (expected_row, actual_row) in enumerate(
        zip(expected_rows, actual_rows), start=1
    ):
        for column, expected_value, actual_value in zip(
            expected_header, expected_row, actual_row
        ):
            if expected_value == actual_value:
                continue
            differing_values += 1
            if len(first_differences) < 20:
                first_differences.append(
                    {
                        "row": row_index,
                        "column": column,
                        "expected": expected_value,
                        "actual": actual_value,
                    }
                )
    valid = (
        expected_header == actual_header
        and len(expected_rows) == len(actual_rows)
        and differing_values == 0
    )
    return {
        "status": "valid" if valid else "invalid",
        "expected_rows": len(expected_rows),
        "actual_rows": len(actual_rows),
        "headers_equal": expected_header == actual_header,
        "differing_values": differing_values,
        "first_differences": first_differences,
    }


def remove_ignored_metadata(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: remove_ignored_metadata(child)
            for key, child in value.items()
            if key not in IGNORED_METADATA_FIELDS
        }
    if isinstance(value, list):
        return [remove_ignored_metadata(child) for child in value]
    return value


def compare_geojson(
    expected: pathlib.Path, actual: pathlib.Path
) -> dict[str, Any]:
    expected_value = remove_ignored_metadata(json.loads(expected.read_text()))
    actual_value = remove_ignored_metadata(json.loads(actual.read_text()))
    valid = expected_value == actual_value
    return {
        "status": "valid" if valid else "invalid",
        "expected_features": len(expected_value.get("features", [])),
        "actual_features": len(actual_value.get("features", [])),
        "equal": valid,
    }


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit(
            "usage: compare_valid_updated_science.py DATASET_ID DIMENSION "
            "VALID_UPDATED_DIR CANDIDATE_DIR REPORT_JSON"
        )
    dataset_id, dimension = sys.argv[1:3]
    expected_dir = pathlib.Path(sys.argv[3])
    actual_dir = pathlib.Path(sys.argv[4])
    report_path = pathlib.Path(sys.argv[5])
    stem = f"{dataset_id}_{dimension}"
    comparisons = {
        "results_csv": compare_csv(
            expected_dir / f"{stem}_results.csv",
            actual_dir / f"{stem}_results.csv",
        ),
        "segment_diagnostics_csv": compare_csv(
            expected_dir / f"{stem}_segment_diagnostics.csv",
            actual_dir / f"{stem}_segment_diagnostics.csv",
        ),
        "tiles_geojson": compare_geojson(
            expected_dir / f"{stem}_tiles.geojson",
            actual_dir / f"{stem}_tiles.geojson",
        ),
    }
    valid = all(item["status"] == "valid" for item in comparisons.values())
    report = {
        "status": "valid" if valid else "invalid",
        "dataset_id": int(dataset_id),
        "dimension": dimension,
        "comparison": "zero-tolerance scientific equality",
        "ignored_metadata_fields": sorted(IGNORED_METADATA_FIELDS),
        **comparisons,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    if not valid:
        raise SystemExit(
            f"valid_updated alignment failed for dataset {dataset_id}; "
            f"see {report_path}"
        )
    print(
        f"valid_updated alignment passed for dataset {dataset_id}: "
        "zero CSV/GeoJSON scientific differences"
    )


if __name__ == "__main__":
    main()
