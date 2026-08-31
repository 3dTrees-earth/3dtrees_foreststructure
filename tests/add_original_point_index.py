#!/usr/bin/env python3
"""Copy LAS/LAZ while adding a stable zero-based original record ordinal."""

from __future__ import annotations

import argparse
import copy
import pathlib

import laspy
import numpy as np


DIMENSION_NAME = "OriginalPointIndex"
SELECTIVE_DIMENSIONS = (
    "PredInstance",
    "PredInstance_SAT",
    "PredInstance_FM",
)


def extra_bytes_params(
    dimension: laspy.point.dims.DimensionInfo,
) -> laspy.ExtraBytesParams:
    return laspy.ExtraBytesParams(
        name=dimension.name,
        type=dimension.dtype,
        description=dimension.description,
        offsets=dimension.offsets,
        scales=dimension.scales,
        no_data=dimension.no_data,
    )


def indexed_header(source_header: laspy.LasHeader) -> laspy.LasHeader:
    output_header = copy.deepcopy(source_header)
    original_extra_dimensions = list(source_header.point_format.extra_dimensions)
    original_extra_names = [item.name for item in original_extra_dimensions]
    output_header.remove_extra_dims(original_extra_names)
    output_header.add_extra_dim(
        laspy.ExtraBytesParams(name=DIMENSION_NAME, type=np.uint64)
    )
    dimensions_by_name = {
        item.name: item for item in original_extra_dimensions
    }
    ordered_names = [
        name for name in SELECTIVE_DIMENSIONS if name in dimensions_by_name
    ]
    ordered_names.extend(
        name for name in original_extra_names if name not in ordered_names
    )
    for name in ordered_names:
        output_header.add_extra_dim(extra_bytes_params(dimensions_by_name[name]))
    return output_header


def add_original_point_index(
    source_path: pathlib.Path,
    output_path: pathlib.Path,
    chunk_points: int,
) -> None:
    with laspy.open(source_path) as source:
        source_header = source.header
        if DIMENSION_NAME in source_header.point_format.dimension_names:
            raise ValueError(f"{DIMENSION_NAME} already exists")
        output_header = indexed_header(source_header)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        ordinal = 0
        with laspy.open(
            output_path,
            mode="w",
            header=output_header,
            do_compress=True,
        ) as writer:
            for points in source.chunk_iterator(chunk_points):
                indexed = laspy.ScaleAwarePointRecord.zeros(
                    len(points), header=output_header
                )
                for dimension in source_header.point_format.dimension_names:
                    indexed[dimension] = points[dimension]
                indexed[DIMENSION_NAME] = np.arange(
                    ordinal, ordinal + len(points), dtype=np.uint64
                )
                writer.write_points(indexed)
                ordinal += len(points)
        if ordinal != source_header.point_count:
            raise RuntimeError(
                f"indexed {ordinal} of {source_header.point_count} source points"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--chunk-points", type=int, default=1_000_000)
    args = parser.parse_args()
    if args.chunk_points < 1:
        raise ValueError("--chunk-points must be positive")
    add_original_point_index(args.source, args.output, args.chunk_points)


if __name__ == "__main__":
    main()
