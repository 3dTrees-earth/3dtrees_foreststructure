# 3Dtrees Forest Structure

`3dtrees_foreststructure` computes forest-structure indices for fixed-size,
optimized Analysis Tiles inside an audited point-cloud footprint.

The current baseline accepts exactly one LAS/LAZ point cloud and one
inclusion-only GeoJSON Audit AOI. AOI coordinates are interpreted directly in
the point cloud's local XY coordinate space.

## Build

```bash
docker build -t 3dtrees-foreststructure:local .
```

## Run

```bash
mkdir -p output
docker run --rm --network none \
  -v "$PWD/input:/in:ro" \
  -v "$PWD/output:/out" \
  3dtrees-foreststructure:local \
  --point-cloud /in/point_cloud.laz \
  --aoi /in/aoi.geojson \
  --output-dir /out
```

The baseline output is `forest_structure_tiles.csv`, with one deterministic
row per complete Analysis Tile. Run the image with `--help` to inspect the
available parameters and their defaults.

## Test

The acceptance test builds the image and exercises only the public container
CLI against a small point-cloud/AOI fixture:

```bash
make test
```

## Status

This repository is under active development. GeoPackage and exclusion support,
spatial/raster exports, optional Instance Dimension metrics, performance work,
and the Galaxy wrapper are tracked as subsequent vertical slices.

