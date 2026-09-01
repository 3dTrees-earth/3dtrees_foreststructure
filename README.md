# 3Dtrees ForestStructure

ForestStructure calculates fixed-tile forest metrics from one LAS/LAZ point
cloud and an optional audited area of interest. It produces tile metrics,
segment diagnostics, vector tiles, a DTM, a CHM, and a tile overview.

The recommended workflow uses a canonical COPC for spatial streaming while
preserving the scientific behavior of the ordered source LAZ. See
[`COPC_REVIEW_GUIDE.md`](COPC_REVIEW_GUIDE.md) for the design, failure fixes,
and validation evidence.

The unchanged scientific reference is
[`reference/Indices_Final_run.R`](reference/Indices_Final_run.R), SHA-256
`746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`.

## Build

Build the base image and the ordered-COPC image:

```bash
make build IMAGE=3dtrees-foreststructure:v0.1.2
make build-julia-memory-safe \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

## Prepare a canonical COPC

Do not use an arbitrary COPC. Build it from the ordered LAS/LAZ so it contains
the validated `OriginalPointIndex` needed to restore source record order:

```bash
FORESTSTRUCTURE_JULIA_IMAGE=3dtrees-foreststructure:copc-local \
FORESTSTRUCTURE_TEST_CPUS=10 \
FORESTSTRUCTURE_TEST_MEMORY_GIB=30 \
bash tests/build_original_order_copc.sh \
  /data/original.laz \
  /data/original.copc.laz \
  /data/original.copc.order.json
```

The builder preserves all point values, places the supported instance
dimensions in selectively readable positions, validates every source index,
and publishes the COPC only after validation succeeds.

## Run

The validated controlled profile is 10 CPUs, a 30 GiB hard memory limit, a
25 GiB internal budget, and one LAScatalog worker:

```bash
docker run --rm --network none \
  --cpus 10 \
  --memory 30g \
  --memory-swap 30g \
  --user "$(id -u):$(id -g)" \
  --env FORESTSTRUCTURE_THREADS=10 \
  --env FORESTSTRUCTURE_CATALOG_WORKERS=1 \
  --volume /local/input:/in:ro \
  --volume /local/output:/out \
  --volume /local/work:/work \
  3dtrees-foreststructure:copc-local \
  --point-cloud /in/original.copc.laz \
  --original-point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id 150 \
  --output-dir /out \
  --temp-dir /work \
  --memory-budget-gib 25
```

`--original-point-cloud` is optional. When supplied, it is used only for
header identity and provenance checks; scientific point reads still use COPC.
Plain LAS/LAZ input is also supported directly.

Supported instance dimensions are:

- `PredInstance`
- `PredInstance_SAT`
- `PredInstance_FM`

Missing dimensions are skipped. Available dimensions are processed
independently so their segment IDs and results cannot mix.

## Inputs and outputs

The AOI is interpreted in the point cloud's local XY coordinate space and is
not reprojected. Without an AOI, the full point-cloud extent is tiled.

For each available instance dimension, the run writes:

- `<dataset>_<dimension>_results.csv`
- `<dataset>_<dimension>_segment_diagnostics.csv`
- `<dataset>_<dimension>_tiles.geojson`

Shared outputs are:

- `<dataset>_dtm.tif`
- `<dataset>_chm.tif`
- `<dataset>_tiles.png`
- `<dataset>_aoi_conversion.json`
- `<dataset>_julia_memory_safe_run.json`
- `<dataset>_performance.csv`

Outputs are computed in a staging directory, validated as a complete set, and
then promoted. A failed run does not publish a partial result set.

## Tests

Run the core container tests:

```bash
make test
make test-julia-memory-safe
```

Verify ordered LAZ and COPC equality for all three instance dimensions:

```bash
make test-copc-all-instance-dimensions
```

Validate one real dataset against an existing oracle:

```bash
make test-valid-updated-copc-alignment \
  DATASET_ID=150 \
  COPC_LAZ=/path/to/input.copc.laz \
  ORIGINAL_LAZ=/path/to/original.laz \
  AOI_GEOJSON=/path/to/aoi.geojson \
  VALID_UPDATED_DIR=/path/to/oracle \
  INSTANCE_DIMENSION=PredInstance
```

The acceptance comparison requires zero differences in result CSVs, segment
diagnostics, tile GeoJSON, DTM cells, and CHM cells.

## Repository layout

- `src/` — analysis and container entrypoint code
- `tests/` — conversion, regression, and differential validation
- `reference/` — unchanged scientific reference script
- `benchmarks/` — benchmark scripts and compact result data
- `Dockerfile.julia-memory-safe` — ordered-COPC image
- `COPC_REVIEW_GUIDE.md` — detailed implementation explanation
