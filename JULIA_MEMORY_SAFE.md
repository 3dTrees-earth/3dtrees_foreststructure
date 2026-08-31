# Ordered-COPC Julia-parity pipeline

## Purpose

This execution path reproduces the scientific behavior of the unchanged Julia
Gäßler script while processing one dataset at a time with bounded memory and
COPC spatial streaming.

The immutable oracle is committed at
[`reference/Indices_Final_run.R`](reference/Indices_Final_run.R), SHA-256
`746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`.
See [`CHANGELOG.md`](CHANGELOG.md) for a detailed, itemized comparison with the
reference script and the complete validation evidence.

## Required COPC contract

A scientifically valid COPC must be built from the original ordered LAS/LAZ by
`tests/build_original_order_copc.sh`. It contains:

1. a zero-based unsigned 64-bit `OriginalPointIndex`;
2. available instance dimensions in the order `PredInstance`,
   `PredInstance_SAT`, `PredInstance_FM`;
3. all remaining source ExtraBytes after the required dimensions.

The builder validates the complete unique point-index range, header identity
and per-instance-dimension fingerprints over index, XYZ and label values.

Runtime preflight rejects:

- COPCs without `OriginalPointIndex`;
- duplicate, missing or out-of-range indexes;
- required order/instance dimensions beyond lidR 4.3.2's first nine
  selectively readable ExtraBytes;
- point-count or header mismatches against an optional original companion;
- unsupported files above 2,147,483,647 points.

## Processing behavior

Every DTM, CHM, segmentation and tile read remains a spatial COPC read. After
lidR returns a chunk, the runtime sorts it by `OriginalPointIndex` before any
scientific operation. That restores original LAZ record order without reading
the whole point cloud or abandoning COPC spatial pruning.

The runtime:

- converts Audit GeoJSON to a deterministic local-XY GeoPackage;
- computes one shared tile grid, DTM and CHM;
- processes every available instance dimension independently;
- skips missing `PredInstance`, `PredInstance_SAT` or `PredInstance_FM`;
- spills exact segment summaries into deterministic on-disk partitions;
- publishes disk-backed DTM/CHM rasters;
- validates a complete staged artifact set before replacing older outputs;
- records selectors, package versions, source identity and resource peaks.

An original non-COPC LAS/LAZ can still be processed directly. If an instance
dimension lies after ExtraByte ordinal 9, the entrypoint creates and validates
a temporary selective projection for that dimension.

## Fine-coordinate DTM fallback

The normal path calls pinned lidR 4.3.2 without modifying coordinates. If and
only if TIN interpolation raises the exact integer-conversion error seen on
fine-scale projected coordinates, the runtime rescales the in-memory
classified DTM copy to the smallest safe decimal XY scale and retries the same
TIN algorithm. Source LAS/LAZ and COPC files remain unchanged.

## Build

Build the default image first if the pinned base is not already present, then
build the ordered-COPC image:

```bash
make build IMAGE=3dtrees-foreststructure:v0.1.2
make build-julia-memory-safe \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

## Convert an ordered source to canonical COPC

The helper uses the ForestStructure image to add/validate dimensions and the
pinned Smart Tile image for Untwine conversion:

```bash
FORESTSTRUCTURE_JULIA_IMAGE=3dtrees-foreststructure:copc-local \
FORESTSTRUCTURE_TEST_CPUS=10 \
FORESTSTRUCTURE_TEST_MEMORY_GIB=30 \
bash tests/build_original_order_copc.sh \
  /data/original.laz \
  /data/original.indexed.copc.laz \
  /data/original.indexed.copc.order.json
```

Conversion and analysis should run sequentially inside each worker slot so
their hard memory limits do not overlap.

## Run

Validated controlled profile:

- 10 CPUs;
- 30 GiB hard memory and swap limit;
- 25 GiB internal budget;
- one LAScatalog worker.

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
  --volume /local/ssd-work:/work \
  3dtrees-foreststructure:copc-local \
  --point-cloud /in/original.indexed.copc.laz \
  --original-point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id 150 \
  --output-dir /out \
  --temp-dir /work \
  --memory-budget-gib 25
```

`--original-point-cloud` is optional and is used only for preflight header
identity checks. It is never a LAScatalog source.

Eight validated slots at this profile cap aggregate worker memory at 240 GiB
and CPU allocation at 80 CPUs.

## Output contract

For each available instance dimension:

- `<dataset>_<dimension>_results.csv`;
- `<dataset>_<dimension>_segment_diagnostics.csv`;
- `<dataset>_<dimension>_tiles.geojson`.

Shared artifacts:

- `<dataset>_dtm.tif`;
- `<dataset>_chm.tif`;
- `<dataset>_tiles.png`;
- `<dataset>_aoi_conversion.json`;
- `<dataset>_julia_memory_safe_run.json`;
- `<dataset>_performance.csv`.

The command always recomputes. Existing dataset artifacts are replaced only
after the fresh incoming set passes internal validation. Promotion failures
restore the preceding set.

## Tests

Core synthetic suite:

```bash
make test-julia-memory-safe \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

Distinct primary/SAT/FM ordered-LAZ versus COPC differential:

```bash
make test-copc-all-instance-dimensions \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

Dataset 150 against the committed Julia oracle:

```bash
make test-julia-memory-safe-dataset150 \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local \
  DATASET150_LAZ=/path/to/80.laz \
  DATASET150_GPKG=/path/to/80.gpkg
```

One canonical COPC against a `valid_updated` oracle:

```bash
make test-valid-updated-copc-alignment \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local \
  DATASET_ID=150 \
  COPC_LAZ=/path/to/150.indexed.copc.laz \
  ORIGINAL_LAZ=/path/to/original.laz \
  AOI_GEOJSON=/path/to/150_aois.geojson \
  VALID_UPDATED_DIR=/path/to/valid_updated \
  INSTANCE_DIMENSION=PredInstance
```

## Validation summary

- 36 real production datasets: exact `PredInstance` equality against
  `valid_updated`;
- real dataset 2160: exact SAT/FM equality between ordered source LAZ and
  canonical COPC for CSV, diagnostics, GeoJSON, DTM and CHM;
- distinct three-dimension synthetic fixture: all 15 artifacts byte-identical;
- dataset 2160 COPC analysis: 405.399 s and 12,356.855 MiB cgroup peak under
  the 10-CPU/30-GiB profile.

No cohort processing, container publication or production worker restart is
performed by the test commands.
