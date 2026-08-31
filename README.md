# 3Dtrees Forest Structure

`3dtrees_foreststructure` computes forest-structure indices for fixed-size
Analysis Tiles across a point cloud, optionally constrained by an audited
footprint.

The unchanged scientific reference is committed at
[`reference/Indices_Final_run.R`](reference/Indices_Final_run.R). Its SHA-256
is `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`.
[`CHANGELOG.md`](CHANGELOG.md) documents every intentional implementation and
execution difference from that script.

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

The historical `v0.1.0` release predates the ordered-COPC parity work and must
not be used for new scientific processing. After this work is reviewed and
merged, use the immutable `sha-<commit>` GitHub Container Registry tag or a new
release tag created from that merge commit. Historical tags and commits remain
available as provenance and are not rewritten.

### Ordered-COPC Julia-parity pipeline

The validated entrypoint accepts an original LAS/LAZ or a canonical COPC with
`OriginalPointIndex`, converts local-XY Audit GeoJSON to a same-basename
GeoPackage, restores original record order after every spatial COPC read and
processes `PredInstance`, `PredInstance_SAT` and `PredInstance_FM`
independently. The controlled profile is 10 CPUs, 30 GiB hard memory, a 25 GiB
internal budget and one LAScatalog worker:

```bash
make build-julia-memory-safe
FORESTSTRUCTURE_JULIA_IMAGE=3dtrees-foreststructure:julia-memory-safe-local \
  bash tests/build_original_order_copc.sh \
  /local/input/original.laz \
  /local/input/original.indexed.copc.laz

docker run --rm --network none \
  --cpus 10 --memory 30g --memory-swap 30g \
  --user "$(id -u):$(id -g)" \
  --env FORESTSTRUCTURE_THREADS=10 \
  --env FORESTSTRUCTURE_CATALOG_WORKERS=1 \
  -v /local/input:/in:ro -v /local/output:/out -v /local/work:/work \
  3dtrees-foreststructure:julia-memory-safe-local \
  --point-cloud /in/original.indexed.copc.laz \
  --original-point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id 150 --output-dir /out --temp-dir /work \
  --memory-budget-gib 25 --sensor ULS --country Test
```

This path always recomputes, even if valid dataset-prefixed artifacts already
exist. It replaces them only after the fresh incoming set validates. See
[`JULIA_MEMORY_SAFE.md`](JULIA_MEMORY_SAFE.md) for the exact execution
differences, failure semantics, selectors, resource contract and validation
commands.

## Run

```bash
mkdir -p output
docker run --rm --network none \
  -v "$PWD/input:/in:ro" \
  -v "$PWD/output:/out" \
  3dtrees-foreststructure:local \
  --point-cloud /in/point_cloud.laz \
  --aoi /in/aoi.geojson \
  --dataset-id 150 \
  --output-dir /out
```

The tool always optimizes the fixed-size grid placement within the usable AOI.
Its grid-search resolution is configurable with `--grid-search-step` and
defaults to 0.5 m. Run the image with `--help` to inspect all available
scientific and runtime parameters and their defaults.

The thread budget is applied automatically to every phase. Grid placement uses
forked workers and tile metrics retain the full lidR thread budget. Buffered
DTM, CHM, and segment catalog chunks use `future` multisession workers, capped
separately by `--catalog-workers` (2 by default), and each catalog worker uses
one lidR thread. Keeping process concurrency below the CPU allowance prevents
dense COPC chunks from collectively exhausting the container memory limit.
Segment workers additionally cap `data.table` at five threads; DTM, CHM, and
tile-metric thread behavior is unchanged so scientific raster and tile values
remain reproducible.

To cover the complete point cloud without an Audit AOI, omit `--aoi`:

```bash
docker run --rm --network none \
  -v "$PWD/input:/in:ro" \
  -v "$PWD/output:/out" \
  3dtrees-foreststructure:local \
  --point-cloud /in/point_cloud.laz \
  --dataset-id 150 \
  --output-dir /out
```

Tree metrics are optional. Repeat `--instance-dimension` to provide extra-byte
names to process (comma-separated names are also accepted). Every requested
name present in the LAS/LAZ header is processed in one global segment pass;
missing names are skipped. The defaults are `PredInstance`,
`PredInstance_SAT`, and `PredInstance_FM`. Each available dimension gets its
own tile and segment CSV so IDs and metrics from different segmentations never
mix. If none exists, the run still succeeds and writes a header-only fallback
segment CSV; every tree/segment field in the fallback tile CSV is `NA`. Trees
are aggregated globally within each dimension and assigned to exactly one tile
by their apex, including trees spanning tile boundaries.

The global segment pass reads XYZ plus only the active instance ExtraByte. For
an original non-COPC input whose dimension occurs after lidR's individually
selectable first nine ExtraBytes, the ordered pipeline creates a validated
temporary single-dimension projection. The canonical COPC builder places the
order and supported instance dimensions first; runtime preflight rejects a
non-canonical COPC rather than loading every ExtraByte. Per-chunk voxel, layer
and apex summaries are written to temporary uncompressed RDS files partitioned
into 64 deterministic instance-ID buckets. The parent finalizes one bucket at
a time and deletes the temporary store on success or failure. This preserves
global tree metrics and output ordering while preventing all chunk summaries
and their concatenated copies from occupying memory simultaneously. Instance
dimensions are processed sequentially, so SAT/FM alternatives do not multiply
the chunk's peak memory.

Every DTM, CHM, and segment catalog chunk must complete. Empty or geometrically
degenerate raster chunks contribute aligned no-data rasters; worker errors are
reported as failures instead of allowing partial scientific outputs. Raster
extent checks tolerate only coordinate-scale floating-point noise at an
otherwise identical grid boundary.

The disk-backed DTM overlap mosaic scans every chunk for CRS metadata and uses
the point-cloud CRS as a fallback when all chunks are CRS-less. This keeps
sparse empty chunks while ensuring that the final DTM retains its source CRS.
Conflicting chunk CRSs still fail validation. The CRS is assigned as metadata
only; coordinates and raster values are neither reprojected nor resampled.

For the Julia-memory-safe path, the point-cloud header is authoritative at
publication time. A source LAS/LAZ without CRS produces final DTM and CHM
GeoTIFFs with no GDAL coordinate system and CRS-less tile geometries, even when
`terra` heuristically interprets small local coordinates as longitude and
latitude. A source with CRS retains its source WKT. This operation changes
metadata only and never reprojects or resamples values.

R/lidR cannot represent a single LAS/LAZ/COPC file containing more than
2,147,483,647 points. Such inputs stop during binary-header preflight with the
machine-readable flag `unsupported_lidr_point_count` and must be split before
ForestStructure processing.

The dataset ID is a required positive integer and prefixes every artifact.
For each available dimension, both
`<dataset-id>_<instance-dimension>_results.csv` and
`<dataset-id>_<instance-dimension>_segment_diagnostics.csv` are written with
the supplied upstream schemas. Their `file` column is the input basename;
`sensor` and `country` are `NA` until workflow metadata is connected. With no
available dimension, the fallback names are `<dataset-id>_results.csv` and
`<dataset-id>_segment_diagnostics.csv`. The legacy `--segment-diagnostics`
flag remains accepted as a deprecated no-op.

Tree filtering defaults to at least 100 occupied 0.2 m voxels, an apex above
3 m, a minimum 0.5 m PCA thickness, and at least three occupied 1 m height
layers; each threshold is a CLI parameter.

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
| `--chm-resolution` | 0.5 m | Full-point-cloud canopy-height raster resolution |
| `--gap-height-threshold` | 3 m | Canopy-gap threshold |
| `--minimum-tree-voxels` | 100 | Minimum occupied voxels per accepted tree |
| `--apex-minimum-height` | 3 m | Strict lower apex-height threshold |
| `--minimum-tree-thickness` | 0.5 m | Minimum smallest PCA extent |
| `--minimum-occupied-layers` | 3 | Minimum occupied 1 m height layers |

Advanced/runtime controls affect execution or optional artifacts, not grid
placement:

| Option | Default | Meaning |
| --- | ---: | --- |
| `--dtm-chunk-size` | 60 m | LAScatalog DTM chunk width |
| `--chunk-size` | 60 m | LAScatalog global-segment chunk width |
| `--dtm-buffer` | 20 m | PTD/TIN chunk-edge buffer |
| `--threads` | 0 | Preserve lidR's container default; positive values set an explicit count |
| `--catalog-workers` | 2 | Memory-bounded LAScatalog process cap; limited further by `--threads` |
| `--instance-dimension` | common aliases | Repeatable extra-byte dimension; missing dimensions are skipped |
| `--segment-diagnostics` | deprecated | Accepted for compatibility; the segment CSV is always emitted |
| `--performance-report` | off | Emit phase timings, peak RSS, counts, threads, and parameters |

Each invocation writes:

- `<dataset-id>_<instance-dimension>_results.csv`: one deterministic row per
  valid Analysis Tile for each available instance dimension;
- `<dataset-id>_<instance-dimension>_segment_diagnostics.csv`: one row per
  global segment for that dimension;
- `<dataset-id>_<instance-dimension>_tiles.geojson`: the machine-readable tile
  footprints and dimension-specific metrics;
- fallback CSV/GeoJSON names without an instance-dimension suffix when no
  configured dimension exists;
- `<dataset-id>_tiles.png`: a human-readable overview of the Audit AOI or
  point-cloud extent, exclusions when applicable, numbered tiles, north arrow,
  and scale;
- `<dataset-id>_dtm.tif`: the full-point-cloud terrain model; and
- `<dataset-id>_chm.tif`: one canopy-height raster for the complete point
  cloud, independent of the Audit AOI.

The complete DTM and CHM are never materialized as one in-memory R raster.
LAScatalog workers write bounded chunk rasters, the DTM overlap mosaic is
evaluated disk-to-disk, and VRTs are streamed into tiled, compressed GeoTIFFs.
Per-tile CHMs exist only transiently in memory while reproducing the upstream
rumple, gap-fraction, standard-deviation, and coefficient-of-variation
calculations; they are not exported.

If no complete tile fits, the run still succeeds: the CSV contains headers,
the GeoJSON is an empty FeatureCollection, the PNG explains that zero tiles
were valid, both global rasters are returned, and the segment CSV follows the
normal global-segment behavior.

## Processing design and upstream compatibility

The implementation intentionally preserves the calculations, thresholds,
column names, rounding, and deterministic row ordering of the supplied
upstream R script. The production wrapper adds audit-aware tiling, bounded
LAScatalog processing, multiple instance dimensions, explicit artifacts, and
failure checks around that scientific core.

One run executes these stages in order:

1. Validate the CLI, LAS/LAZ header, point-count limit, and optional Audit AOI.
2. Build the deterministic 20 m Analysis Tile grid.
3. Produce disk-backed global DTM and CHM rasters from bounded catalog chunks.
4. Read only XYZ, return fields, and required ExtraBytes for segmentation;
   spill deterministic segment summaries to temporary bucket files.
5. Finalize each instance dimension and assign each segment to one tile by its
   apex.
6. Calculate the upstream tile metrics and publish dimension-specific CSV and
   GeoJSON products plus the PNG and rasters.

The DTM catalog selection remains the upstream-compatible `xyz`. The PTD/TIN
path therefore behaves exactly like the supplied reference pipeline, including
its fallback when return fields are unavailable. `ReturnNumber` and
`NumberOfReturns` are retained for segmentation together with every required
instance ExtraByte; they are not exported as result columns. Missing configured
instance dimensions are skipped and do not fail a dataset.

The main known limit is dense DTM construction: pathological inputs can still
exceed available memory inside lidR/terra even with two catalog workers. Such
runs fail explicitly; the tool never accepts partial catalog output. Inputs
above 2,147,483,647 points are rejected during preflight because R/lidR cannot
represent their point count safely.

## Test

The acceptance test builds the image and exercises only the public container
CLI against deterministic synthetic point-cloud and AOI fixtures. It covers
complete point-cloud tiling without an AOI, GeoJSON and GeoPackage
inclusion/exclusion semantics, zero-tile output, and the spatial/raster output
contract:

```bash
make test
```

The supplied dataset-150 upstream CSVs are retained as a strict parity oracle
for the original `80.laz`. The audit rejects any other point cloud, including
a COPC, and compares all 146 tiles and 397 segments with zero tolerance:

```bash
DATASET150_LAZ=/path/to/80.laz \
  make test-dataset150
```

This audit is deliberately stricter than the production validator and is not
part of the release-publishing workflow because the source LAZ is not public.
It uses the historical 146-tile
`tests/fixtures/dataset150/150_upstream_tiles.geojson` footprint. Julia's
unchanged script run against the authoritative supplied `80.gpkg` instead
produces 147 tiles; the separate Julia-memory-safe validation preserves that
authoritative footprint and compares all 147 rows. A second regression converts
the operational `150_aois.geojson` to `80.gpkg` and compares all 82 rows.
The historical implementation incorrectly rescaled ordinary in-memory XY
coordinates before TIN and selected return fields for the DTM catalog. The
current implementation first passes classified coordinates directly to pinned
lidR 4.3.2 and preserves the DTM `xyz` selection. Only the exact fine-coordinate
integer-conversion failure triggers a guarded in-memory DTM retry. Return fields
remain available where segmentation needs them.

Validated dataset outputs can also be checked byte-for-byte, excluding only the
runtime performance report and validation metadata:

```bash
python tests/compare_validated_outputs.py \
  150 /path/to/validated/foreststructure /path/to/candidate/output
```

## Status

The ordered-COPC implementation has passed zero-tolerance scientific
validation:

- 36 real production datasets reproduced `valid_updated` exactly for
  `PredInstance`;
- dataset 2160 reproduced an ordered source-LAZ run exactly for both
  `PredInstance_SAT` and `PredInstance_FM`, including every CSV value, all 85
  segment rows, GeoJSON, DTM and CHM;
- the dataset-2160 ordered-LAZ and COPC DTM/CHM files were byte-identical;
- a synthetic fixture with deliberately different primary/SAT/FM labels
  produced byte-identical ordered-LAZ and COPC output for all 15 artifacts.

The validated local image is not itself a published release. Review and merge
this branch, then publish an immutable SHA/container-digest image before
changing production workers. Complete evidence, prior failure explanations and
intentional differences from the Julia script are in
[`CHANGELOG.md`](CHANGELOG.md).

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
