#!/usr/bin/env python3
"""Memory-bounded validation of an original-order indexed COPC."""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any

import laspy
import numpy as np


INDEX_DIMENSION = "OriginalPointIndex"
INSTANCE_DIMENSIONS = (
    "PredInstance",
    "PredInstance_SAT",
    "PredInstance_FM",
)
MASK64 = (1 << 64) - 1


def mix64(values: np.ndarray) -> np.ndarray:
    values = values.astype(np.uint64, copy=True)
    values ^= values >> np.uint64(30)
    values *= np.uint64(0xBF58476D1CE4E5B9)
    values ^= values >> np.uint64(27)
    values *= np.uint64(0x94D049BB133111EB)
    values ^= values >> np.uint64(31)
    return values


def tuple_hash(
    indexes: np.ndarray,
    points: laspy.ScaleAwarePointRecord,
    dimension: str,
) -> np.ndarray:
    result = mix64(indexes.astype(np.uint64, copy=False) + np.uint64(0x9E3779B97F4A7C15))
    for seed, name in (
        (0x243F6A8885A308D3, "X"),
        (0x13198A2E03707344, "Y"),
        (0xA4093822299F31D0, "Z"),
        (0x082EFA98EC4E6C89, dimension),
    ):
        values = np.asarray(points[name]).astype(np.uint64, copy=False)
        result ^= mix64(values + np.uint64(seed))
        result = mix64(result)
    return result


def update_fingerprint(
    fingerprint: dict[str, int], hashes: np.ndarray
) -> None:
    fingerprint["sum_a"] = (
        fingerprint["sum_a"] + int(np.sum(hashes, dtype=np.uint64))
    ) & MASK64
    fingerprint["xor_a"] ^= int(np.bitwise_xor.reduce(hashes, initial=np.uint64(0)))
    secondary = mix64(hashes ^ np.uint64(0x452821E638D01377))
    fingerprint["sum_b"] = (
        fingerprint["sum_b"] + int(np.sum(secondary, dtype=np.uint64))
    ) & MASK64
    fingerprint["xor_b"] ^= int(
        np.bitwise_xor.reduce(secondary, initial=np.uint64(0))
    )


def fingerprint_json(fingerprint: dict[str, int]) -> dict[str, str]:
    return {name: f"{value:016x}" for name, value in fingerprint.items()}


def header_metadata(reader: laspy.LasReader) -> dict[str, Any]:
    header = reader.header
    return {
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


def source_fingerprint(
    path: pathlib.Path,
    dimensions: list[str],
    chunk_points: int,
) -> tuple[dict[str, Any], dict[str, dict[str, int]]]:
    fingerprints = {
        dimension: {"sum_a": 0, "xor_a": 0, "sum_b": 0, "xor_b": 0}
        for dimension in dimensions
    }
    ordinal = 0
    with laspy.open(path) as reader:
        metadata = header_metadata(reader)
        for dimension in dimensions:
            if dimension not in reader.header.point_format.dimension_names:
                raise ValueError(f"source is missing {dimension}")
        for points in reader.chunk_iterator(chunk_points):
            indexes = np.arange(ordinal, ordinal + len(points), dtype=np.uint64)
            for dimension in dimensions:
                update_fingerprint(
                    fingerprints[dimension],
                    tuple_hash(indexes, points, dimension),
                )
            ordinal += len(points)
    if ordinal != metadata["point_count"]:
        raise RuntimeError(
            f"read {ordinal} of {metadata['point_count']} source points"
        )
    return metadata, fingerprints


def candidate_fingerprint(
    path: pathlib.Path,
    dimensions: list[str],
    chunk_points: int,
) -> tuple[dict[str, Any], dict[str, dict[str, int]], dict[str, Any]]:
    fingerprints = {
        dimension: {"sum_a": 0, "xor_a": 0, "sum_b": 0, "xor_b": 0}
        for dimension in dimensions
    }
    with laspy.open(path) as reader:
        metadata = header_metadata(reader)
        available_dimensions = set(reader.header.point_format.dimension_names)
        for required in (*dimensions, INDEX_DIMENSION):
            if required not in available_dimensions:
                raise ValueError(f"candidate is missing {required}")
        point_count = metadata["point_count"]
        seen = np.zeros(point_count, dtype=np.bool_)
        read_count = 0
        minimum_index = None
        maximum_index = None
        duplicate_indexes = 0
        out_of_range_indexes = 0
        for points in reader.chunk_iterator(chunk_points):
            indexes = np.asarray(points[INDEX_DIMENSION], dtype=np.uint64)
            read_count += len(indexes)
            if len(indexes) == 0:
                continue
            minimum_index = min(
                int(indexes.min()),
                minimum_index if minimum_index is not None else MASK64,
            )
            maximum_index = max(
                int(indexes.max()),
                maximum_index if maximum_index is not None else 0,
            )
            in_range = indexes < np.uint64(point_count)
            out_of_range_indexes += int(np.count_nonzero(~in_range))
            valid_indexes = indexes[in_range].astype(np.int64, copy=False)
            if len(valid_indexes):
                unique_indexes, counts = np.unique(valid_indexes, return_counts=True)
                duplicate_indexes += int(np.sum(counts - 1))
                duplicate_indexes += int(np.count_nonzero(seen[unique_indexes]))
                seen[unique_indexes] = True
            for dimension in dimensions:
                update_fingerprint(
                    fingerprints[dimension],
                    tuple_hash(indexes, points, dimension),
                )
    index_validation = {
        "read_count": read_count,
        "minimum": minimum_index,
        "maximum": maximum_index,
        "duplicate_indexes": duplicate_indexes,
        "out_of_range_indexes": out_of_range_indexes,
        "missing_indexes": int(np.count_nonzero(~seen)),
        "unique_complete_range": (
            read_count == metadata["point_count"]
            and minimum_index == 0
            and maximum_index == metadata["point_count"] - 1
            and duplicate_indexes == 0
            and out_of_range_indexes == 0
            and not np.any(~seen)
        ),
    }
    return metadata, fingerprints, index_validation


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--dimension", action="append", default=None)
    parser.add_argument("--chunk-points", type=int, default=1_000_000)
    args = parser.parse_args()
    if args.chunk_points < 1:
        raise ValueError("--chunk-points must be positive")

    with laspy.open(args.source) as source_reader:
        source_dimensions = set(source_reader.header.point_format.dimension_names)
        dimensions = args.dimension or [
            name for name in INSTANCE_DIMENSIONS if name in source_dimensions
        ]
    if not dimensions:
        raise ValueError("source has no supported instance dimensions to validate")

    source_metadata, source_digests = source_fingerprint(
        args.source, dimensions, args.chunk_points
    )
    candidate_metadata, candidate_digests, index_validation = candidate_fingerprint(
        args.candidate, dimensions, args.chunk_points
    )
    header_equal = all(
        source_metadata[name] == candidate_metadata[name]
        for name in ("point_count", "scales", "offsets", "mins", "maxs")
    )
    fingerprint_equal_by_dimension = {
        dimension: source_digests[dimension] == candidate_digests[dimension]
        for dimension in dimensions
    }
    fingerprint_equal = all(fingerprint_equal_by_dimension.values())
    valid = (
        header_equal
        and fingerprint_equal
        and index_validation["unique_complete_range"]
    )
    report = {
        "status": "valid" if valid else "invalid",
        "comparison": (
            "streaming dual-64-bit tuple fingerprints over "
            "(OriginalPointIndex,X,Y,Z,dimension) with exact index uniqueness"
        ),
        "dimensions": dimensions,
        "header_equal": header_equal,
        "fingerprint_equal": fingerprint_equal,
        "fingerprint_equal_by_dimension": fingerprint_equal_by_dimension,
        "source_fingerprints": {
            dimension: fingerprint_json(source_digests[dimension])
            for dimension in dimensions
        },
        "candidate_fingerprints": {
            dimension: fingerprint_json(candidate_digests[dimension])
            for dimension in dimensions
        },
        "index_validation": index_validation,
        "source": source_metadata,
        "candidate": candidate_metadata,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    if not valid:
        raise SystemExit(f"indexed COPC validation failed; see {args.report}")
    print(
        "indexed COPC streaming validation passed: "
        f"points={source_metadata['point_count']} dimensions={','.join(dimensions)}"
    )


if __name__ == "__main__":
    main()
