# 3Dtrees Forest Structure

`3dtrees_foreststructure` computes forest-structure indices for fixed-size
Analysis Tiles across a point cloud, optionally constrained by an audited
footprint.

The container accepts exactly one LAS/LAZ point cloud. A GeoJSON or GeoPackage
Audit AOI is optional. Without `--aoi`, the tool reads the XY extent from the
point-cloud header and creates the minimum number of complete square tiles
needed to cover it. Boundary tiles can extend beyond that rectangular extent,
which ensures that every source point belongs to a tile. With `--aoi`, tiles
must be completely contained in the usable audited footprint.

AOI coordinates are interpreted directly in the point cloud's local XY
coordinate space; the tool does not reproject the AOI. The run fails when the
usable AOI has no positive-area overlap with the point-cloud XY extent, which
prevents a mismatched local coordinate frame from silently producing empty
tiles.

GeoJSON is the canonical audit handoff. A bare Polygon/MultiPolygon, or a
FeatureCollection without a `role` property, is inclusion-only. When `role` is
present, production Audit values `inclusion` and `exclusion` are accepted,
along with the shorter aliases `include` and `exclude`. GeoPackages must
contain an `include` layer and may contain an `exclude` layer. Tiles must be
completely inside the inclusion geometry and may not overlap exclusions.

## Build

```bash
docker build -t 3dtrees-foreststructure:local .
```

The image pins the complete `lidR` 4.3.2 source archive and verifies its
SHA-256 digest during the build. This keeps the PTD implementation
reproducible even while `lidR` is absent from the current CRAN package index.

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

The thread budget is applied automatically to every phase. Grid placement uses
forked workers, buffered DTM and segment catalog chunks use `future`
multisession workers, and each catalog worker uses one lidR thread to avoid
nested oversubscription. Tile metrics retain the full lidR thread budget.

To cover the complete point cloud without an Audit AOI, omit `--aoi`:

```bash
docker run --rm --network none \
  -v "$PWD/input:/in:ro" \
  -v "$PWD/output:/out" \
  3dtrees-foreststructure:local \
  --point-cloud /in/point_cloud.laz \
  --output-dir /out
```

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
| `--dtm-chunk-size` | 200 m | LAScatalog DTM chunk width |
| `--chunk-size` | 60 m | LAScatalog global-segment chunk width |
| `--dtm-buffer` | 20 m | PTD/TIN chunk-edge buffer |
| `--threads` | 0 | Preserve lidR's container default; positive values set an explicit count |
| `--instance-dimension` | common aliases | Repeatable ordered extra-byte candidate |
| `--segment-diagnostics` | off | Emit the optional global segment CSV |
| `--performance-report` | off | Emit phase timings, peak RSS, counts, threads, and parameters |

Each invocation writes:

- `forest_structure_tiles.csv`: one deterministic row per valid Analysis Tile;
- `forest_structure_tiles.geojson`: the machine-readable tile footprints and
  their IDs/metrics, so downstream consumers can spatially join CSV results;
- `forest_structure_tiles.png`: a human-readable overview of the Audit AOI or
  point-cloud extent, exclusions when applicable, numbered tiles, north arrow,
  and scale;
- `forest_structure_dtm.tif`: the full-point-cloud terrain model; and
- `chm/tile_<tile-id>_chm.tif`: one canopy-height raster per valid tile.

If no complete tile fits, the run still succeeds: the CSV contains headers,
the GeoJSON is an empty FeatureCollection, the PNG explains that zero tiles
were valid, the DTM is returned, and the CHM directory is empty.

## Test

The acceptance test builds the image and exercises only the public container
CLI against deterministic synthetic point-cloud and AOI fixtures. It covers
complete point-cloud tiling without an AOI, GeoJSON and GeoPackage
inclusion/exclusion semantics, zero-tile output, and the spatial/raster output
contract:

```bash
make test
```

## Status

The stable container and measured performance slice are complete. The Galaxy
wrapper remains the intentionally later integration slice.

## Performance

The optimized implementation stops the exact placement search as soon as it
reaches the mathematical AOI-area upper bound, distributes remaining offset
candidates across the requested threads, and minimizes dimensions read by the
common first-extra-byte segment path. Per-tile metric and CHM work runs in
deterministic tile order while retaining the requested lidR thread budget
inside each tile. This avoids multiplying memory through forked point-cloud
workers and prevents nested lidR/OpenMP parallelism; it also validates that
exactly one result is returned for every tile before writing aggregate
outputs. Candidate ordering, tile-row order, and first-best tie-breaking
remain deterministic.
Deterministic benchmarks measured
31.8% lower wall time for 50,000 points/9 tiles and 14.7% lower wall time for
500,000 points/36 tiles, with slightly lower peak RSS and no scientific output
differences at `1e-9`. See [`benchmarks/README.md`](benchmarks/README.md) for the
reproduction commands, measurements, rejected alternatives, and runtime
guidance.
