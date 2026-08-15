#!/usr/bin/env python3
"""Exactly compare an original-LAZ run with the dataset-150 upstream oracle."""

from __future__ import annotations

import csv
import pathlib
import sys


METADATA_FIELDS = {"file", "sensor", "country"}


def read_csv(path: pathlib.Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return reader.fieldnames or [], list(reader)


def compare_rows(
    label: str,
    expected_rows: list[dict[str, str]],
    actual_rows: list[dict[str, str]],
    fields: list[str],
) -> list[str]:
    if len(expected_rows) != len(actual_rows):
        raise ValueError(
            f"{label}: expected {len(expected_rows)} rows, got {len(actual_rows)}"
        )
    differences: list[str] = []
    for index, (expected, actual) in enumerate(
        zip(expected_rows, actual_rows), start=1
    ):
        row_label = f"{label} row {index}"
        for field in fields:
            if field in METADATA_FIELDS:
                continue
            if expected[field] != actual[field]:
                differences.append(
                    f"{row_label} {field}: "
                    f"{expected[field]!r} != {actual[field]!r}"
                )
    return differences


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: compare_dataset150.py ACTUAL_DIR ORACLE_DIR POINT_CLOUD_BASENAME"
        )
    actual_dir = pathlib.Path(sys.argv[1])
    oracle_dir = pathlib.Path(sys.argv[2])
    point_cloud_basename = sys.argv[3]

    tile_oracle_path = oracle_dir / "150_results.csv"
    segment_oracle_path = oracle_dir / "150_segment_diagnostics.csv"
    tile_actual_path = actual_dir / "150_PredInstance_results.csv"
    segment_actual_path = (
        actual_dir / "150_PredInstance_segment_diagnostics.csv"
    )

    tile_fields, tile_oracle = read_csv(tile_oracle_path)
    actual_tile_fields, tile_actual = read_csv(tile_actual_path)
    segment_fields, segment_oracle = read_csv(segment_oracle_path)
    actual_segment_fields, segment_actual = read_csv(segment_actual_path)

    if actual_tile_fields != tile_fields:
        raise AssertionError("tile CSV header differs from the upstream oracle")
    if actual_segment_fields != segment_fields:
        raise AssertionError("segment CSV header differs from the upstream oracle")
    if len(tile_actual) != 146:
        raise AssertionError(f"expected 146 tile rows, got {len(tile_actual)}")
    if len(segment_actual) != 397:
        raise AssertionError(f"expected 397 segment rows, got {len(segment_actual)}")

    for label, rows in (("tile", tile_actual), ("segment", segment_actual)):
        if any(row["file"] != point_cloud_basename for row in rows):
            raise AssertionError(f"{label} file metadata is not the input basename")
        if any(row["sensor"] != "NA" or row["country"] != "NA" for row in rows):
            raise AssertionError(f"{label} sensor/country metadata must be NA")

    differences = compare_rows(
        "tile",
        tile_oracle,
        tile_actual,
        tile_fields,
    )
    differences.extend(compare_rows(
        "segment",
        segment_oracle,
        segment_actual,
        segment_fields,
    ))
    if differences:
        preview = "\n".join(f"- {difference}" for difference in differences[:20])
        remainder = len(differences) - 20
        suffix = f"\n- ... and {remainder} more" if remainder > 0 else ""
        raise SystemExit(
            f"dataset 150 differs from the upstream oracle in "
            f"{len(differences)} values:\n{preview}{suffix}"
        )
    print(
        "dataset 150 exact LAZ regression passed: "
        "146 tiles and 397 segments"
    )


if __name__ == "__main__":
    main()
