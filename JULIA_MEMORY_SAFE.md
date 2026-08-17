# Julia-faithful memory-safe pipeline

## Purpose and source of truth

This is a separate execution path. It does not replace the default
ForestStructure entrypoint or image.

The scientific source of truth is Julia Gäßler's unchanged
`Indices_Final_run.R`:

- SHA-256:
  `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`
- fixed 20 m tiles and 0.5 m offset search;
- PTD seed resolution 20 m;
- 1 m DTM, 60 m catalog chunks and 20 m DTM buffer;
- 0.2 m structural voxels, 70 m maximum height and 0.5 m vegetation cutoff;
- unchanged formulas, filters, comparisons, rounding, row order and
  `NA` serialization.

The design goal is to change execution and input handling without changing
those calculations. The medium-large oracle pass documented in
[`MEDIUM_LARGE_VALIDATION.md`](MEDIUM_LARGE_VALIDATION.md) found that this goal
is not yet met for every CRS-less local-coordinate dataset. CRS publication is
now aligned explicitly with the source LAS/LAZ: a source without CRS produces
DTM, CHM and vector outputs without assigned CRS metadata. DTM chunk rasters
now retain the numeric order returned by `catalog_apply()` instead of being
sorted lexically. Fresh full runs of datasets 970 and 2062 reproduce Julia's
scientific CSVs byte-for-byte and every shared DTM cell at zero tolerance. The
publication extent now comes from the same pinned lidR 4.3.2 raster layout used
by Julia. Dataset 970 reproduces the complete DTM geometry and every cell at
zero tolerance; dataset 2062 still needs a fresh run with that correction. The
remaining AOI ring-order validation issue must also be corrected and rechecked
before cohort processing.

## What was added

- `Dockerfile.julia-memory-safe` builds a distinct image on the validated
  `v0.1.2` base.
- `src/run_julia_memory_safe.R` is the distinct public entrypoint.
- `src/aoi_conversion.R` and `src/convert_aoi.R` implement the reproducible
  local-XY GeoJSON-to-GeoPackage conversion.
- `src/project_instance_dimension.py` implements the bounded streaming
  projection required when an instance ExtraByte occurs after ordinal 9.
- `run.R` exposes its existing analysis body as `run_analysis()`, while its
  normal `main()` and default CLI remain in place.

The Julia-memory-safe entrypoint:

1. rejects COPCs and accepts exactly one original LAS/LAZ;
2. stages it by local symbolic link and builds a local `.lax`;
3. converts the supplied GeoJSON to a same-basename GeoPackage;
4. uses one LAScatalog worker by default or the validated
   `FORESTSTRUCTURE_CATALOG_WORKERS=2` override;
5. reads DTM and tile points with `xyz`;
6. calls `classify_ground(..., last_returns = FALSE)`;
7. processes each present instance dimension in a separate pass;
8. reads segmentation with `xyz1` through `xyz9`, never `xyz0`,
   `xyzrn`, `*`, or an unfiltered whole-file read;
9. spills DTM, CHM and segment intermediates to `--temp-dir`;
10. validates a staged output set before replacing prior dataset artifacts.

Missing `PredInstance`, `PredInstance_SAT`, or `PredInstance_FM`
dimensions are logged and skipped. Each present dimension gets independent
results, diagnostics and tile GeoJSON files.

The `buffer` column that lidR adds internally to LAScatalog chunks is allowed
as catalog bookkeeping. It is not a source LAS attribute. Runtime checks reject
any other unexpected DTM, tile or segment column.

The point-cloud header is authoritative for output CRS state. If it has no
CRS, GDAL projection metadata is explicitly removed from the final DTM and CHM
and tile geometries remain CRS-less; this prevents `terra` from labelling small
local coordinates as WGS84. If the source has a CRS, its WKT is retained. This
metadata alignment does not reproject, resample, or change raster values.

## ExtraBytes after ordinal 9

lidR 4.3.2 can select individual ExtraBytes only at ordinals 1 through 9.
For a requested dimension after ordinal 9, the entrypoint creates a temporary
LAZ whose only ExtraByte is that dimension. The projection preserves and
checks:

- ordered raw integer X/Y/Z;
- XYZ scale and offset;
- bounds, CRS and point count;
- ordered raw instance values;
- the instance ExtraByte datatype.

The projection is written in bounded one-million-point chunks and then read by
lidR with `xyz1`. It is deleted with the job directory. The projection LAS
still has the structural fields required by LAS point format 0, but the
ForestStructure reader exposes only X, Y, Z and the requested ExtraByte.

## Memory behavior

The container contract is 75 GiB hard memory, no additional swap, and a
60 GiB internal budget. The internal gate checks current RSS plus conservative
allocation estimates before segment `rbindlist()`, `unique()` and
`prcomp()`.

Segment summaries are stored in deterministic instance-ID partitions. A
partition that cannot fit is recursively split on disk. A single segment that
cannot fit is stopped with
`FORESTSTRUCTURE_FLAG single_segment_exceeds_memory_budget`; its PCA is never
replaced with a different algorithm. An in-memory adapter is retained for
small reference tests, and regression tests require it to equal the disk
adapter.

The performance CSV records parent-process high-water RSS, the cgroup-wide
memory peak, and observed high-water temporary-disk use. Promotion is rejected
if either memory measurement reaches the internal budget. A failed run leaves
existing output artifacts untouched and cleans its incoming and temporary
directories.

The production bucket count is 64. A validated internal-only
`FORESTSTRUCTURE_SEGMENT_BUCKET_COUNT` override exists to force smaller disk
partitions during equivalence testing; it does not change scientific
parameters or the public CLI.

## Build and run

```bash
make build-julia-memory-safe \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:julia-memory-safe
```

```bash
docker run --rm --network none \
  --cpus 20 \
  --memory 75g \
  --memory-swap 75g \
  --user "$(id -u):$(id -g)" \
  --env FORESTSTRUCTURE_THREADS=20 \
  --volume /local/input:/in:ro \
  --volume /local/output:/out \
  --volume /local/ssd-work:/work \
  3dtrees-foreststructure:julia-memory-safe \
  --point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id 150 \
  --output-dir /out \
  --temp-dir /work \
  --memory-budget-gib 60 \
  --sensor ULS \
  --country Test \
  --instance-dimension PredInstance \
  --instance-dimension PredInstance_SAT \
  --instance-dimension PredInstance_FM
```

The command always recomputes. Existing dataset-prefixed artifacts are moved
aside only after the fresh candidate set validates, then the new set is
promoted by same-filesystem renames. A promotion error rolls back the previous
set.

## Dataset 150 validation

Inputs:

- original `80.laz` SHA-256:
  `d767997ce5868a98fb9dc0a688cb3d300fc8b7cee45571eadcf9b6102c9f9789`;
- authoritative `80.gpkg` SHA-256:
  `cc7befe0c55ce5e09c66c4eda062cbc947937ea005e7cc80161a028685f5c643`;
- Julia script SHA-256:
  `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`.

The authoritative GeoPackage was exported once to canonical `80.geojson`
and converted back with the new converter. Authoritative, canonical and runtime
geometry are equal at zero tolerance. The normalized geometry SHA-256 is
`99c23a622e2b4cce9ace6f2a2b0e9f96b3f91ede6b591520cc16f490ee80aa7a`;
area is `67666.8367` and bounds are
`292034.1654, 6456586.0447, 292303.8260, 6456861.1072`.

Important correction: this authoritative footprint produces **147** complete
tiles in Julia's unchanged script (best offset 15.5 m, 19.5 m), not 146. The
older 146-row repository fixture uses
`tests/fixtures/dataset150/150_upstream_tiles.geojson`, a different footprint
constructed from those historical tiles. The validation did not alter or
discard the authoritative 147th tile.

Julia's unchanged script and the final memory-safe image were both run fresh
from original `80.laz` using the canonical conversion workflow. Results:

- 147 tile rows, byte-identical CSV SHA-256
  `7c24e34b4d245dccaa619d7faaafaf6bea126d4e1898d4bacbde0f190314114b`;
- 397 segment rows, byte-identical CSV SHA-256
  `ab563cb44a837688a2c1e73fef7d617255c97b552e768c32b76cf0521eb26b65`;
- zero differing headers, rows or values;
- identical 1 m DTM geometry, NA mask, and all 77,248 cells at zero
  tolerance (72,437 populated cells and zero differences);
- selector `xyz1` for `PredInstance`, and `xyz` for DTM and tiles;
- 673.676 MiB parent R high-water RSS;
- 2455.023 MiB cgroup-wide peak;
- 21.126 MiB observed temporary-disk high-water;
- exit code 0 and `OOMKilled=false`.

This final run deliberately used 512 segment buckets, reran over an existing
valid artifact set, and promoted nine freshly recomputed artifacts only after
validation. It completed in 536.283 seconds. The resulting tile and segment
CSVs remained byte-identical to the Julia oracle.

The original script does not normally export its DTM. The test runner parses
the immutable source and evaluates its top-level expressions in their original
order, then attaches an exit-only tracer immediately after
`build_global_dtm()` is defined. The tracer serializes that function's return
value as `FLT8S` without rewriting the script or changing the returned object.
The full instrumented run still reproduced every tile and segment CSV value,
proving that the capture did not perturb Julia's analysis.

Dataset-150 validation image:

- tag: `3dtrees-foreststructure:julia-memory-safe-dataset150-final3`;
- candidate source-file manifest SHA-256:
  `867e3dbd16e53da28fadbd713d972d4416ddc09fdee639f5e063561427b03cb6`;
- image ID:
  `sha256:26b76ef4a6f014fedfa5c08ad0616e869761d5dbea0b78fc6bd3bd43dcdcfb45`;
- OCI revision label:
  `b6319882d536809db6a8b27a9df170d1108309f0-source-867e3dbd`;
- base `v0.1.2` image ID:
  `sha256:3eee1d12654002a5cbb4bcc0bca13fcf93622307b1a4fe899e35ce9393a3dac9`;
- lidR 4.3.2, data.table 1.18.2.1, sf 1.1.0, terra 1.9.11,
  rlas 1.8.6, future 1.70.0, laspy 2.6.1 and lazrs 0.7.0.

This is a local-only image, so it has no registry `RepoDigest`; the immutable
local image ID above is the available content identity.

Ordering-corrected revalidation image:

- tag:
  `3dtrees-foreststructure:julia-memory-safe-order-fixed-20260817`;
- image ID:
  `sha256:325ece1e7072055858a340a3ea544a034b8149382744d638ebfe1c1684878fe4`;
- OCI revision label: `working-tree-dtm-catalog-order-20260817`;
- OCI version label: `julia-memory-safe-order-fixed-20260817`;
- base `v0.1.2` image ID:
  `sha256:3eee1d12654002a5cbb4bcc0bca13fcf93622307b1a4fe899e35ce9393a3dac9`;
- lidR 4.3.2;
- local-only `RepoDigests`: empty.

The complete synthetic suite and fresh full dataset-970 and dataset-2062
revalidations used this exact image ID. Their preserved reports are under
`/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/order_fix_20260817/`.

The preserved authoritative-footprint validation directory is:
`/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/dataset150_7RCbbiDz`.

### Operational Audit AOI

The production `150_aois.geojson` was also converted to `80.gpkg`, then used
for fresh runs of both Julia's unchanged script and the final image:

- source GeoJSON SHA-256:
  `1d565d50081d97b782965fa58319e6f659ccc2f2a0da3932c5057506be3f7385`;
- normalized geometry SHA-256:
  `69646b53f11d508c60571611cb3b31f9cc5fef4d70788cf13dd2c6040db2f972`;
- tile geometry SHA-256:
  `5be72d72050d88cbfe34e20bced97f421266a2b50f50a9a5df47875c0a66f430`;
- 82 tile rows and 397 segment rows;
- zero differing headers, rows or values;
- 650.422 MiB parent RSS, 2507.898 MiB cgroup peak, 21.043 MiB observed
  temporary-disk high-water, exit 0 and `OOMKilled=false`.

The preserved operational-AOI validation directory is:
`/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/dataset150_operational_aoi_gjjycSbw`.

## Tests

```bash
make test-julia-memory-safe \
  FORESTSTRUCTURE_SKIP_BUILD=1 \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:julia-memory-safe-dataset150-final3
```

The synthetic suite verifies three value-identical instance dimensions,
ordinals 11/12/13, ordered projection hashes, rerunning over valid artifacts,
forced 256-bucket disk partitioning, temporary cleanup, disk/reference adapter
equality and a controlled impossible memory-budget failure with no promoted
output.

The dataset-150 tests additionally compare the captured Julia DTM and the
candidate DTM cell-for-cell with zero tolerance.

The complete Julia comparison is reproducible with:

```bash
FORESTSTRUCTURE_SKIP_BUILD=1 \
FORESTSTRUCTURE_JULIA_IMAGE=3dtrees-foreststructure:julia-memory-safe-dataset150-final3 \
bash tests/test_julia_memory_safe_dataset150.sh \
  /path/to/80.laz \
  /path/to/80.gpkg \
  /path/to/Indices_Final_run.R
```

The operational Audit-AOI comparison is reproducible with:

```bash
FORESTSTRUCTURE_SKIP_BUILD=1 \
FORESTSTRUCTURE_JULIA_IMAGE=3dtrees-foreststructure:julia-memory-safe-dataset150-final3 \
bash tests/test_julia_memory_safe_dataset150_operational_aoi.sh \
  /path/to/80.laz \
  /path/to/150_aois.geojson \
  /path/to/Indices_Final_run.R
```

No cohort processing or release publication is performed by these tests.
