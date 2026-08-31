#!/usr/bin/env python3
"""Distinguish LAS point-order changes from point-content changes."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
from typing import Any

import laspy
import numpy as np


def read_tuples(
    path: pathlib.Path, dimension: str
) -> tuple[np.ndarray, np.ndarray | None, np.ndarray | None, dict[str, Any]]:
    with laspy.open(path) as reader:
        las = reader.read()
        header = reader.header
    dtype = np.dtype(
        [
            ("X", las.X.dtype),
            ("Y", las.Y.dtype),
            ("Z", las.Z.dtype),
            (dimension, las[dimension].dtype),
        ]
    )
    tuples = np.empty(len(las.points), dtype=dtype)
    tuples["X"] = las.X
    tuples["Y"] = las.Y
    tuples["Z"] = las.Z
    tuples[dimension] = las[dimension]
    gps_time = (
        np.asarray(las.gps_time)
        if "gps_time" in header.point_format.dimension_names
        else None
    )
    original_point_index = (
        np.asarray(las["OriginalPointIndex"])
        if "OriginalPointIndex" in header.point_format.dimension_names
        else None
    )
    metadata = {
        "path": str(path),
        "point_count": int(header.point_count),
        "scales": header.scales.tolist(),
        "offsets": header.offsets.tolist(),
        "mins": header.mins.tolist(),
        "maxs": header.maxs.tolist(),
        "point_format": int(header.point_format.id),
        "extra_dimensions": [
            item.name for item in header.point_format.extra_dimensions
        ],
    }
    return tuples, gps_time, original_point_index, metadata


def digest(values: np.ndarray) -> str:
    return hashlib.sha256(values.tobytes(order="C")).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("expected", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--dimension", default="PredInstance")
    args = parser.parse_args()

    expected, expected_gps_time, expected_point_index, expected_metadata = read_tuples(
        args.expected, args.dimension
    )
    candidate, candidate_gps_time, candidate_point_index, candidate_metadata = read_tuples(
        args.candidate, args.dimension
    )
    counts_equal = len(expected) == len(candidate)
    ordered_equal = counts_equal and np.array_equal(expected, candidate)
    sequence_differences = (
        int(np.count_nonzero(expected != candidate)) if counts_equal else None
    )
    expected_sorted = np.sort(expected, order=expected.dtype.names)
    candidate_sorted = np.sort(candidate, order=candidate.dtype.names)
    multiset_equal = counts_equal and np.array_equal(
        expected_sorted, candidate_sorted
    )
    sorted_differences = (
        int(np.count_nonzero(expected_sorted != candidate_sorted))
        if counts_equal
        else None
    )
    gps_time_available = (
        expected_gps_time is not None and candidate_gps_time is not None
    )
    gps_time_unique = False
    gps_time_duplicate_points = None
    gps_time_max_multiplicity = None
    expected_gps_time_nondecreasing = False
    gps_time_sorted_differences = None
    gps_time_restores_expected_order = False
    gps_xyz_instance_restores_expected_order = False
    if gps_time_available and counts_equal:
        unique_gps_time, gps_time_counts = np.unique(
            expected_gps_time, return_counts=True
        )
        gps_time_duplicate_points = int(
            len(expected_gps_time) - len(unique_gps_time)
        )
        gps_time_max_multiplicity = int(gps_time_counts.max(initial=0))
        gps_time_unique = gps_time_duplicate_points == 0 and (
            len(np.unique(candidate_gps_time)) == len(candidate_gps_time)
        )
        expected_gps_time_nondecreasing = bool(
            np.all(expected_gps_time[1:] >= expected_gps_time[:-1])
        )
        candidate_gps_order = np.argsort(candidate_gps_time, kind="stable")
        gps_time_sorted_differences = int(
            np.count_nonzero(candidate[candidate_gps_order] != expected)
        )
        gps_time_restores_expected_order = np.array_equal(
            candidate[candidate_gps_order], expected
        )
        candidate_composite_order = np.lexsort((
            candidate[args.dimension],
            candidate["Z"],
            candidate["Y"],
            candidate["X"],
            candidate_gps_time,
        ))
        expected_composite_order = np.lexsort((
            expected[args.dimension],
            expected["Z"],
            expected["Y"],
            expected["X"],
            expected_gps_time,
        ))
        gps_xyz_instance_restores_expected_order = (
            np.array_equal(candidate[candidate_composite_order], expected)
            and np.array_equal(expected_composite_order, np.arange(len(expected)))
        )
    original_point_index_available = candidate_point_index is not None
    original_point_index_unique = False
    original_point_index_restores_expected_order = False
    if original_point_index_available and counts_equal:
        original_point_index_unique = (
            len(np.unique(candidate_point_index)) == len(candidate_point_index)
        )
        point_index_order = np.argsort(candidate_point_index, kind="stable")
        original_point_index_restores_expected_order = (
            original_point_index_unique
            and np.array_equal(candidate[point_index_order], expected)
            and np.array_equal(
                candidate_point_index[point_index_order],
                np.arange(len(candidate), dtype=candidate_point_index.dtype),
            )
        )
    report = {
        "status": "same_order" if ordered_equal else (
            "reordered_only" if multiset_equal else "content_differs"
        ),
        "dimension": args.dimension,
        "counts_equal": counts_equal,
        "ordered_equal": ordered_equal,
        "multiset_equal": multiset_equal,
        "sequence_differences": sequence_differences,
        "sorted_differences": sorted_differences,
        "gps_time_available": gps_time_available,
        "gps_time_unique": gps_time_unique,
        "gps_time_duplicate_points": gps_time_duplicate_points,
        "gps_time_max_multiplicity": gps_time_max_multiplicity,
        "expected_gps_time_nondecreasing": expected_gps_time_nondecreasing,
        "gps_time_sorted_differences": gps_time_sorted_differences,
        "gps_time_restores_expected_order": gps_time_restores_expected_order,
        "gps_xyz_instance_restores_expected_order": (
            gps_xyz_instance_restores_expected_order
        ),
        "original_point_index_available": original_point_index_available,
        "original_point_index_unique": original_point_index_unique,
        "original_point_index_restores_expected_order": (
            original_point_index_restores_expected_order
        ),
        "expected_order_sha256": digest(expected),
        "candidate_order_sha256": digest(candidate),
        "expected_sorted_sha256": digest(expected_sorted),
        "candidate_sorted_sha256": digest(candidate_sorted),
        "expected": expected_metadata,
        "candidate": candidate_metadata,
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
