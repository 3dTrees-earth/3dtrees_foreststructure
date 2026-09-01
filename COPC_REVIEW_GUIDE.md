# Ordered-COPC implementation review guide

This guide is for reviewing the COPC changes without having to reconstruct the
design from individual commits. The scientific goal is strict: processing a
canonical COPC must reproduce the ordered-LAZ/Julia result while reading point
data through COPC's spatial hierarchy.

## The problem being solved

Untwine reorganizes LAS/LAZ records into COPC spatial order. That is desirable
for bounded spatial reads, but record order is no longer the source order seen
by the original Julia/R workflow. Some lidR operations resolve ties using input
order, so feeding a generic COPC can change a small number of downstream values
even when every XYZ and instance value survived conversion.

A second, independent failure occurs in lidR's DTM TIN path when large absolute
coordinates use extremely fine LAS scales. The Delaunay implementation converts
absolute XY coordinates to signed 32-bit integers. Dataset 2011, for example,
used 0.000001 m scales around easting 550,000 m and failed with:

```text
Internal error in C_interpolate_delaunay: xy coordinates were not converted to integer.
Scale factors are likely to be invalid.
```

## End-to-end data flow

```text
ordered LAS/LAZ
    |
    | add OriginalPointIndex = zero-based source record position
    v
indexed ordered LAZ
    |
    | Untwine spatial reordering
    v
canonical COPC
    |
    | validate header + every index exactly once + tuple fingerprints
    v
published canonical COPC
    |
    | lidR spatial/chunk/window reads from COPC
    v
bounded in-memory chunk
    |
    | sort chunk rows by OriginalPointIndex
    v
Julia-compatible point order -> unchanged scientific operations
```

The original LAS/LAZ can be mounted with `--original-point-cloud`, but it is
used only to validate point count/XYZ bounds and to preserve the historical
source filename in output metadata. Scientific point reads always use the COPC.

## File-by-file review map

### `tests/add_original_point_index.py`

- Streams the ordered source instead of loading the complete cloud.
- Adds a UInt64 `OriginalPointIndex` equal to the zero-based source row.
- Moves `OriginalPointIndex`, `PredInstance`, `PredInstance_SAT`, and
  `PredInstance_FM` into lidR's first nine selectively readable ExtraBytes.
- Copies every original dimension value and ExtraByte definition unchanged.

This is the only step that defines original order. It runs before Untwine.

### `tests/build_original_order_copc.sh`

- Runs indexing, Untwine conversion, and validation in isolated containers.
- Applies the same configurable CPU and hard memory limits to every stage.
- Builds beside the destination and publishes with one rename only after all
  validation checks pass.
- Never publishes a partially built or invalid candidate.

### `tests/validate_indexed_copc_streaming.py`

- Verifies exact point-count, XYZ bounds, scale, and offset equality.
- Uses a bitset to prove that all indices from `0` through `n - 1` occur exactly
  once, with no missing, duplicate, or out-of-range values.
- Compares order-independent dual fingerprints over
  `(OriginalPointIndex, raw X, raw Y, raw Z, instance value)` for every supported
  instance dimension present in the source.
- Reads both files in bounded chunks.

The bitset gives an exact index-completeness proof. Fingerprints bind each index
to its geometry and scientific instance value without assuming physical order.

### `src/run_julia_memory_safe.R`

- Accepts canonical `.copc.laz` as the actual scientific input.
- Rejects COPC without `OriginalPointIndex`.
- Requires the order key and requested instance dimensions within lidR's first
  nine ExtraBytes, preserving selective spatial streaming.
- Skips LAX creation for COPC because COPC already carries a spatial hierarchy.
- Optionally validates an original LAS/LAZ companion by header count and bounds.
- Records COPC use, order restoration, selectors, and companion validation in
  the run provenance JSON.

### `src/run.R`

- `restore_original_point_order()` validates and sorts each bounded COPC read by
  `OriginalPointIndex` before DTM, CHM, segmentation, or tile calculations.
- `catalog_selection_for_dimensions()` adds only the required ExtraByte selector
  to the existing XYZ catalog/window request.
- DTM, CHM, segment, and tile functions receive the order key explicitly. There
  is no hidden global COPC mode.
- Plain LAS/LAZ passes `NULL`, so its established order and behavior are unchanged.
- `tin_compatible_xy_scale()` retries only the known lidR Delaunay integer-scale
  error. It calculates the smallest decimal scale that keeps absolute XY below
  95% of `INT32_MAX`, never chooses finer precision than the source, and changes
  only the in-memory DTM retry object.

The DTM retry does not rewrite the source LAS/LAZ or COPC. It does not alter Z,
segmentation, CHM input storage, or the configured DTM algorithm/resolution.

### `tests/test_copc_all_instance_dimensions.sh`

Creates one controlled fixture with deliberately different values in all three
instance dimensions. It runs ordered LAZ and canonical COPC through the same
image and requires byte-identical outputs for every dimension plus DTM and CHM.
It also proves that the fixture dimensions produce different results from one
another, preventing a vacuous routing test.

### `tests/test_valid_updated_copc_alignment.sh`

Runs a real canonical COPC under explicit CPU/memory limits, asserts COPC and
order-restoration provenance, and compares:

- result CSV values at zero tolerance;
- segment diagnostics at zero tolerance;
- output GeoJSON exactly, excluding only path metadata;
- DTM and CHM geometry, populated-cell masks, and cell values at zero tolerance.

The detailed comparisons live in
`tests/compare_valid_updated_science.py` and
`tests/compare_valid_updated_raster.R`. Both write their report before failing,
so an acceptance failure retains exact row/cell counts and sampled differences.

### Cohort acceptance scripts

- `tests/test_valid_updated_cohort.sh` proves that selected legacy `valid` or
  `pending_xy_rescale` results really differ from `valid_updated`, converts the
  ordered source to canonical COPC, and requires the new output to match the
  oracle.
- `tests/test_valid_updated_oracle_cohort.sh` applies the same conversion and
  zero-tolerance checks to datasets that have a `valid_updated` oracle but no
  legacy `valid` result, while recording conversion/runtime/resource evidence.
- `tests/compare_las_point_order.py` is a diagnostic tool used to establish the
  original root cause: it distinguishes physical sequence differences from
  changes in the unordered point-value multiset. Canonical publication uses the
  streaming validator instead because the diagnostic loads complete files.

## What did not change

- Julia's scientific parameter values.
- The released base image's R, lidR, terra, sf, or GDAL versions.
- Tree acceptance thresholds, voxel definitions, raster resolutions, or AOI
  conversion semantics.
- Original LAS/LAZ or COPC files during analysis.
- Plain LAS/LAZ behavior when no point-order dimension is supplied.

The patch changes storage access, deterministic record-order reconstruction,
input validation/provenance, and a narrowly matched DTM error recovery path.

## Acceptance evidence

The automated differential fixture covers `PredInstance`, `PredInstance_SAT`,
and `PredInstance_FM`. The real failed-dataset replay used dataset 2011:

- 23,700,806 source points;
- every `OriginalPointIndex` present exactly once;
- the historical DTM integer-conversion error was reproduced on the old image;
- the patched fallback triggered and the complete pipeline produced nine files;
- 18 segment-diagnostic rows matched the fresh ordered-LAZ control exactly;
- DTM matched across 361 cells with zero differing cells;
- CHM matched across 1,369 cells with zero differing cells;
- COPC peak cgroup memory was approximately 4.59 GiB under a 30 GiB hard limit.

Dataset 2011 had no previously promoted `valid_updated` artifact because its old
run failed at DTM. Therefore its reference was generated fresh from the ordered
original LAZ with the same patched scientific implementation. This isolates the
COPC conversion/order-restoration path while exercising the exact former failure.

## Reviewer commands

Build the image:

```bash
make build-julia-memory-safe JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

Run the controlled three-dimension differential:

```bash
make test-copc-all-instance-dimensions
```

Build and validate a canonical COPC:

```bash
make build-original-order-copc \
  ORIGINAL_LAZ=/path/to/ordered.laz \
  COPC_LAZ=/path/to/canonical.copc.laz
```

Run a dataset/oracle comparison:

```bash
make test-valid-updated-copc-alignment \
  DATASET_ID=123 \
  COPC_LAZ=/path/to/canonical.copc.laz \
  ORIGINAL_LAZ=/path/to/ordered.laz \
  AOI_GEOJSON=/path/to/aoi.geojson \
  VALID_UPDATED_DIR=/path/to/oracle \
  INSTANCE_DIMENSION=PredInstance
```
