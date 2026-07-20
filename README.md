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

Tree metrics are optional. Repeat `--instance-dimension` to provide candidate
extra-byte names in priority order (comma-separated names are also accepted).
The first name present in the LAS/LAZ header is used for one global segment
pass; the defaults are `PredInstance`, `PredInstance_SAT`, `PredInstance_FM`,
and `treeID`. If none exists, the run still succeeds and every tree/segment
field in the tile CSV is `NA`. Trees are aggregated globally and assigned to
exactly one tile by their apex, including trees spanning tile boundaries.

Use `--segment-diagnostics` to additionally write
`segment_diagnostics.csv`. It is omitted by default. Tree filtering defaults
to at least 100 occupied 0.2 m voxels, an apex above 3 m, a minimum 0.5 m PCA
thickness, and at least three occupied 1 m height layers; each threshold is a
CLI parameter.

## Parameters

Scientific controls retain the supplied R script's defaults:

| Option | Default | Meaning |
| --- | ---: | --- |
| `--tile-size` | 20 m | Fixed square Analysis Tile width |
| `--grid-search-step` | 0.5 m | Resolution of the always-on placement search |
| `--ptd-resolution` | 20 m | PTD ground-classification seed resolution |
| `--dtm-resolution` | 1 m | Global terrain raster resolution |
| `--maximum-height` | 70 m | Upper normalized-height cutoff |
| `--voxel-resolution` | 0.2 m | Structural voxel edge length |
| `--vegetation-minimum-height` | 0.5 m | Lower vegetation cutoff |
| `--chm-resolution` | 0.5 m | Per-tile canopy-height raster resolution |
| `--gap-height-threshold` | 3 m | Canopy-gap threshold |
| `--minimum-tree-voxels` | 100 | Minimum occupied voxels per accepted tree |
| `--apex-minimum-height` | 3 m | Strict lower apex-height threshold |
| `--minimum-tree-thickness` | 0.5 m | Minimum smallest PCA extent |
| `--minimum-occupied-layers` | 3 | Minimum occupied 1 m height layers |

Advanced/runtime controls affect execution or optional artifacts, not grid
placement:

| Option | Default | Meaning |
| --- | ---: | --- |
| `--chunk-size` | 60 m | LAScatalog streaming chunk width |
| `--dtm-buffer` | 20 m | PTD/TIN chunk-edge buffer |
| `--threads` | 0 | Preserve lidR's container default; positive values set an explicit count |
| `--instance-dimension` | common aliases | Repeatable ordered extra-byte candidate |
| `--segment-diagnostics` | off | Emit the optional global segment CSV |

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

Complete CLI-contract validation, performance work, and the Galaxy wrapper are
tracked as subsequent vertical slices.
