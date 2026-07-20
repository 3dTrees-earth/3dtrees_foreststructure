# 3Dtrees Forest Structure

`3dtrees_foreststructure` computes forest-structure indices for fixed-size,
optimized Analysis Tiles inside an audited point-cloud footprint.

The container accepts exactly one LAS/LAZ point cloud and one GeoJSON or
GeoPackage Audit AOI. AOI coordinates are interpreted directly in the point
cloud's local XY coordinate space; the tool does not reproject the AOI.

GeoJSON is the canonical audit handoff. A bare Polygon/MultiPolygon, or a
FeatureCollection without a `role` property, is inclusion-only. When `role` is
present, every feature must be `include` or `exclude`. GeoPackages must contain
an `include` layer and may contain an `exclude` layer. Tiles must be completely
inside the inclusion geometry and may not overlap exclusions.

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

The tool always optimizes the fixed-size grid placement within the usable AOI.
Its grid-search resolution is configurable with `--grid-search-step` and
defaults to 0.5 m. Run the image with `--help` to inspect all available
scientific and runtime parameters and their defaults.

Each invocation writes:

- `forest_structure_tiles.csv`: one deterministic row per valid Analysis Tile;
- `forest_structure_tiles.geojson`: the machine-readable tile footprints and
  their IDs/metrics, so downstream consumers can spatially join CSV results;
- `forest_structure_tiles.png`: a human-readable overview of the AOI,
  exclusions, numbered tiles, north arrow, and scale;
- `forest_structure_dtm.tif`: the full-point-cloud terrain model; and
- `chm/tile_<tile-id>_chm.tif`: one canopy-height raster per valid tile.

If no complete tile fits, the run still succeeds: the CSV contains headers,
the GeoJSON is an empty FeatureCollection, the PNG explains that zero tiles
were valid, the DTM is returned, and the CHM directory is empty.

## Test

The acceptance test builds the image and exercises only the public container
CLI against deterministic synthetic point-cloud and AOI fixtures. It covers
GeoJSON and GeoPackage inclusion/exclusion semantics, zero-tile output, and
the spatial/raster output contract:

```bash
make test
```

## Status

Optional Instance Dimension metrics, segment diagnostics, performance work,
and the Galaxy wrapper are tracked as subsequent vertical slices.
