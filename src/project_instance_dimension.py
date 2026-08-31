#!/usr/bin/env python3
"""Stream an XYZ + one ExtraByte LAZ projection and verify ordered values."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import tempfile

import laspy
import numpy as np


def update_hash(digest: "hashlib._Hash", values: np.ndarray) -> None:
    array = np.asarray(values)
    little_endian = array.astype(array.dtype.newbyteorder("<"), copy=False)
    digest.update(little_endian.tobytes(order="C"))


def extra_dimension(header: laspy.LasHeader, name: str):
    for dimension in header.point_format.extra_dimensions:
        if dimension.name == name:
            return dimension
    raise ValueError(f"ExtraByte dimension {name!r} is absent")


def extra_params(dimension) -> laspy.ExtraBytesParams:
    kwargs: dict[str, object] = {
        "name": dimension.name,
        "type": dimension.dtype,
        "description": dimension.description or "",
    }
    if dimension.scales is not None:
        kwargs["scales"] = dimension.scales
    if dimension.offsets is not None:
        kwargs["offsets"] = dimension.offsets
    return laspy.ExtraBytesParams(**kwargs)


def crs_text(header: laspy.LasHeader) -> str | None:
    crs = header.parse_crs()
    return None if crs is None else crs.to_wkt()


def stream_projection(
    source_path: pathlib.Path,
    output_path: pathlib.Path,
    dimension_name: str,
    chunk_points: int,
) -> dict[str, object]:
    source_digest = hashlib.sha256()
    projected_digest = hashlib.sha256()

    with laspy.open(source_path) as source:
        source_header = source.header
        dimension = extra_dimension(source_header, dimension_name)
        output_header = laspy.LasHeader(
            point_format=0,
            version=str(source_header.version),
        )
        output_header.scales = source_header.scales.copy()
        output_header.offsets = source_header.offsets.copy()
        output_header.generating_software = "3dtrees-foreststructure-julia-memory-safe"
        source_crs = source_header.parse_crs()
        if source_crs is not None:
            output_header.add_crs(source_crs)
        output_header.add_extra_dim(extra_params(dimension))

        output_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{output_path.stem}_",
            suffix=".laz",
            dir=output_path.parent,
        )
        os.close(descriptor)
        temporary_path = pathlib.Path(temporary_name)
        try:
            with laspy.open(
                temporary_path,
                mode="w",
                header=output_header,
                do_compress=True,
            ) as writer:
                for points in source.chunk_iterator(chunk_points):
                    projected = laspy.ScaleAwarePointRecord.zeros(
                        len(points),
                        header=output_header,
                    )
                    projected.X = points.X
                    projected.Y = points.Y
                    projected.Z = points.Z
                    projected.array[dimension_name] = points.array[dimension_name]
                    for values in (
                        points.X,
                        points.Y,
                        points.Z,
                        points.array[dimension_name],
                    ):
                        update_hash(source_digest, values)
                    writer.write_points(projected)

            with laspy.open(temporary_path) as projected_source:
                for points in projected_source.chunk_iterator(chunk_points):
                    for values in (
                        points.X,
                        points.Y,
                        points.Z,
                        points.array[dimension_name],
                    ):
                        update_hash(projected_digest, values)
                projected_header = projected_source.header

            if source_digest.digest() != projected_digest.digest():
                raise RuntimeError("ordered XYZ/instance hash differs after projection")
            if source_header.point_count != projected_header.point_count:
                raise RuntimeError("point count differs after projection")
            if not np.array_equal(source_header.scales, projected_header.scales):
                raise RuntimeError("XYZ scales differ after projection")
            if not np.array_equal(source_header.offsets, projected_header.offsets):
                raise RuntimeError("XYZ offsets differ after projection")
            if not np.array_equal(source_header.mins, projected_header.mins):
                raise RuntimeError("XYZ minimum bounds differ after projection")
            if not np.array_equal(source_header.maxs, projected_header.maxs):
                raise RuntimeError("XYZ maximum bounds differ after projection")
            if crs_text(source_header) != crs_text(projected_header):
                raise RuntimeError("CRS differs after projection")
            if [item.name for item in projected_header.point_format.extra_dimensions] != [
                dimension_name
            ]:
                raise RuntimeError("projection contains an unexpected ExtraByte set")
            os.replace(temporary_path, output_path)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise

    return {
        "source": str(source_path.resolve()),
        "projection": str(output_path.resolve()),
        "dimension": dimension_name,
        "source_ordinal": [
            item.name for item in source_header.point_format.extra_dimensions
        ].index(dimension_name)
        + 1,
        "source_datatype": str(dimension.dtype),
        "point_count": source_header.point_count,
        "xyz_instance_ordered_sha256": source_digest.hexdigest(),
        "projection_selector": "xyz1",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--dimension", required=True)
    parser.add_argument("--chunk-points", type=int, default=1_000_000)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.chunk_points < 1:
        raise ValueError("--chunk-points must be positive")
    provenance = stream_projection(
        args.source,
        args.output,
        args.dimension,
        args.chunk_points,
    )
    print(json.dumps(provenance, sort_keys=True))


if __name__ == "__main__":
    main()
