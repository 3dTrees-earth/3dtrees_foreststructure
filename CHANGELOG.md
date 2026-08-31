# Changelog

This changelog records scientific and operational differences from the
immutable Julia Gäßler reference implementation in
[`reference/Indices_Final_run.R`](reference/Indices_Final_run.R). It is more
detailed than a normal release log because scientific parity depends on small
execution details such as point order, raster merge order and LAS ExtraByte
selection.

The reference file is unchanged and has SHA-256
`746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`.

## Unreleased — ordered-COPC Julia-parity pipeline

### Docker and implementation documentation

- Added a dated description of the eight direct-LAZ containers currently
  producing the `valid_updated` baseline, including their exact image/source
  identities, entrypoint, input contract, CPU and memory limits, worker counts
  and non-restarting lifecycle.
- Added a three-way comparison of the immutable Julia script, the currently
  running direct-LAZ image and the ordered-COPC optimized image.
- Expanded the ordered-COPC OCI image metadata to expose its documentation,
  canonical input mode, point-order contract, supported dimensions and
  scientific-reference hash through `docker inspect`.
- These changes are documentation and image metadata only; they do not modify
  the R calculations or the behavior of containers that are already running.

### Outcome

The new execution path preserves the reference script's calculations while
adding bounded-memory execution and spatial COPC streaming. A canonical COPC
contains a stable `OriginalPointIndex`; every spatially selected chunk is
returned to original LAZ record order before scientific calculations. This is
the central requirement for reproducing the reference outputs from COPC.

The implementation supports all available segmentation alternatives:
`PredInstance`, `PredInstance_SAT` and `PredInstance_FM`. Missing alternatives
are reported and skipped, while every present alternative is calculated in an
independent pass and receives independent artifacts.

### Scientific behavior intentionally preserved

The following reference behavior is unchanged:

- 20 m square analysis tiles;
- exhaustive 0.5 m grid-offset candidates and first-best tie behavior;
- complete containment of tiles in the usable AOI;
- global PTD ground classification with a 20 m seed resolution;
- TIN terrain interpolation at 1 m resolution;
- 60 m DTM and segmentation chunks with a 20 m DTM buffer;
- height normalization against the global DTM;
- 0.2 m structural voxels;
- accepted normalized-height interval from 0 m through 70 m;
- vegetation-only threshold strictly above 0.5 m;
- fixed box-counting scales below the 20 m tile width;
- 1 m vertical-complexity layers;
- 0.5 m per-tile CHM used for rumple, gap fraction and CHM spread;
- canopy-gap threshold below 3 m;
- segment apex selection by maximum normalized height;
- segment-to-tile assignment by apex using inclusive lower and exclusive upper
  tile boundaries;
- tree acceptance thresholds of at least 100 occupied voxels, apex strictly
  above 3 m, smallest PCA extent at least 0.5 m and at least three occupied
  1 m layers;
- the bias-corrected Gini calculation;
- all metric formulas, comparisons, four-decimal rounding, column names and
  deterministic output ordering;
- `NA` behavior for unavailable tree metrics.

No approximation was introduced for a scientific metric. Memory pressure is
handled by partitioning exact intermediate tables, never by sampling or by
changing a formula.

### Input discovery and command-line interface

Reference script:

- changes into a hard-coded Windows directory;
- recursively discovers all LAS/LAZ files below hard-coded TLS, MLS and ULS
  folders;
- derives sensor and country from directory names;
- requires a same-basename GeoPackage next to each point cloud;
- processes every discovered file in one R session.

Current implementation:

- processes exactly one explicitly supplied point cloud per container;
- requires a positive dataset ID and explicit output/work directories;
- accepts an Audit AOI as GeoJSON or GeoPackage;
- accepts sensor and country as optional workflow metadata;
- exposes scientific parameters as CLI options while retaining the reference
  defaults;
- isolates failures and memory limits to one dataset;
- emits machine-readable stage and provenance records.

This changes orchestration, not scientific calculations.

### Audit AOI handling

The reference reads one GeoPackage, clears its CRS and unions its geometry.
The current entrypoint additionally:

- accepts canonical GeoJSON;
- recognizes explicit inclusion and exclusion roles;
- validates and unions inclusion geometry;
- subtracts exclusions from the usable footprint;
- converts GeoJSON deterministically to a same-basename runtime GeoPackage;
- records normalized geometry provenance;
- rejects coordinate-frame mismatches and AOIs with no positive-area overlap;
- keeps local XY coordinates planar and performs no reprojection.

For an inclusion-only AOI, tile placement and containment remain equivalent to
the reference script.

### Canonical ordered-COPC conversion

Ordinary COPC creation spatially reorders points. That reordering can change
tie resolution and floating-point accumulation in PTD/TIN, voxelization, apex
selection and PCA. Consequently, a spatially ordered COPC alone is not a valid
replacement for the original ordered LAZ.

The conversion pipeline now:

1. streams the original LAS/LAZ in bounded chunks;
2. adds a zero-based unsigned 64-bit `OriginalPointIndex` equal to the source
   record position;
3. writes required ExtraBytes first in canonical order:
   `OriginalPointIndex`, `PredInstance`, `PredInstance_SAT`,
   `PredInstance_FM`;
4. appends every other source ExtraByte without changing its name, values,
   datatype or metadata;
5. builds the spatial COPC with Untwine;
6. validates point count, scales, offsets, bounds and dimensions;
7. validates that point indexes form the complete unique range
   `0..point_count-1` with no duplicates, gaps or out-of-range values;
8. validates dual 64-bit streaming fingerprints over
   `(OriginalPointIndex, X, Y, Z, instance value)` independently for every
   supported instance dimension present in the source.

The canonical ordering keeps every required selector within lidR 4.3.2's
first nine individually selectable ExtraBytes. Runtime preflight rejects a
non-canonical COPC instead of silently loading every ExtraByte.

### Spatial streaming with original-order restoration

The reference script reads an indexed LAS/LAZ catalog and requests `xyz0` for
DTM, segmentation and per-tile reads. It therefore sees original file order.

The current COPC path:

- retains COPC as the LAScatalog source for DTM, CHM, segmentation and tile
  phases;
- requests XYZ, `OriginalPointIndex` and only the active instance dimension;
- sorts each returned LAS chunk by `OriginalPointIndex` before scientific
  processing;
- rejects missing, duplicated or unexpectedly loaded dimensions;
- never changes the COPC's coordinates or rewrites it during analysis.

This preserves COPC spatial pruning without exposing COPC storage order to the
scientific algorithms.

### Multiple instance dimensions

The reference script is hard-coded to `PredInstance` and produces one results
table and one diagnostic table.

The current implementation:

- detects `PredInstance`, `PredInstance_SAT` and `PredInstance_FM`;
- skips missing dimensions without failing the dataset;
- runs global segment accumulation and finalization separately for each
  present dimension;
- never mixes segment IDs or tree metrics between alternatives;
- emits dimension-qualified results CSV, segment-diagnostics CSV and tiles
  GeoJSON artifacts;
- computes the shared DTM, CHM and tile grid only once.

The segment formulas and filters are identical for every alternative.

### Selective ExtraByte projection

lidR 4.3.2 can select individual ExtraBytes only at ordinals 1 through 9.
For an original non-COPC file whose requested instance dimension occurs later,
the runtime creates a bounded temporary LAZ containing structural LAS fields
plus only that dimension. Raw integer XYZ, scale, offset, bounds, CRS, point
count, point order, values and datatype are checked before it is used.

For canonical COPC, projection is unnecessary because the conversion places
the order and instance dimensions first. A required dimension outside the
selective range is a preflight error with instructions to rebuild the COPC.

### Bounded-memory segment aggregation

The reference stores all per-chunk voxel, height-layer and apex tables in one
R object, then combines them with `rbindlist()` and `unique()`. That is the
principal memory peak.

The current implementation instead:

- writes chunk summaries to deterministic instance-ID partitions on disk;
- processes one partition at a time;
- recursively splits a partition that does not fit the internal budget;
- fails explicitly if one indivisible segment exceeds the budget;
- preserves exact `unique()`, apex, PCA and ordering behavior;
- limits `data.table` threads during segment work;
- cleans temporary partitions on success and failure.

The production partition count is 64. A test-only override exercises deeper
partitioning and must produce identical outputs.

### Disk-backed DTM and CHM publication

The reference asks `catalog_apply()` to automerge raster chunks in memory and
retains the global DTM for later normalization.

The current implementation:

- writes bounded chunk rasters to the temporary directory;
- preserves the numeric LAScatalog result order during overlap resolution;
- builds disk-backed VRT mosaics;
- streams tiled compressed GeoTIFF publication;
- preserves the pinned lidR raster grid instead of recomputing point-covering
  bounds;
- requires every catalog chunk to complete;
- represents empty or geometrically degenerate chunks as aligned no-data
  rasters rather than accepting a partial result;
- rejects conflicting CRS metadata.

These changes bound memory without changing shared raster values or masks.

### Fine-coordinate DTM compatibility fallback

Dataset 2160 uses XY scales of `1e-7` m with large absolute coordinates.
Pinned lidR 4.3.2 can fail inside Delaunay interpolation with
`xy coordinates were not converted to integer`.

The runtime first executes the unchanged reference path. Only after that exact
lidR error does it:

- calculate the smallest safe decimal XY scale for signed 32-bit Delaunay
  coordinates;
- rescale only the in-memory classified DTM LAS copy;
- retry the same TIN algorithm;
- leave the original LAS and canonical COPC unchanged.

Normal inputs never enter this fallback. Tests assert that ordinary scale
factors remain untouched and that the source object is unchanged after the
fine-coordinate retry.

### CRS and local-coordinate metadata

The reference clears the AOI CRS and operates in local planar coordinates.
The current publication path additionally treats the point-cloud header as
authoritative:

- a source without CRS produces CRS-less DTM, CHM and tile geometry;
- a source with CRS retains its WKT;
- no coordinate is reprojected or resampled;
- terra/GDAL heuristics are prevented from mislabelling small local
  coordinates as longitude/latitude.

### Resource controls

The reference relies on ambient R/lidR thread and memory behavior.
The current container exposes and validates:

- Docker CPU and hard memory limits;
- an internal memory budget below the Docker limit;
- a bounded LAScatalog worker count;
- a bounded `data.table` thread count;
- phase timings;
- parent-process and cgroup peak memory;
- temporary-disk high-water use.

The validated controlled profile is 10 CPUs, a 30 GiB Docker memory and swap
limit, a 25 GiB internal budget and one LAScatalog worker. Eight such slots
cap aggregate worker memory at 240 GiB.

### Failure and publication semantics

The reference skips some invalid inputs and writes final CSVs directly at the
end of the multi-file session.

The current runtime:

- validates input headers, point counts, dimensions and AOI overlap before
  analysis;
- rejects files above R/lidR's signed 32-bit point-count limit;
- reports stage-specific, machine-readable failures;
- rejects partial catalog results;
- stages all output under a dataset-specific incoming directory;
- validates the complete fresh artifact set;
- replaces existing artifacts only after validation;
- rolls back the previous set if promotion fails;
- always recomputes, so stale artifacts cannot masquerade as a successful run.

### Additional artifacts

In addition to the reference CSV content, the current runtime produces:

- dimension-qualified tile GeoJSON;
- a human-readable tile overview PNG;
- global DTM and CHM GeoTIFFs;
- AOI conversion provenance;
- run provenance including source hash, point count, selectors, dimensions,
  scientific parameters and package versions;
- a performance/resource CSV.

Metadata-only fields such as the input filename may differ when comparing two
equivalent storage representations. Scientific validation ignores only those
explicit metadata fields and uses zero tolerance everywhere else.

### Exact validation evidence

Production and differential validation completed before this commit:

- 36 real production datasets reproduced their `valid_updated` ground truth
  exactly for `PredInstance`;
- real dataset 2160, containing 68,302,459 points and only
  `PredInstance_SAT`/`PredInstance_FM`, reproduced an ordered-source LAZ run
  exactly for both dimensions;
- dataset 2160 had zero differing SAT/FM result values, zero differences in
  all 85 combined segment-diagnostic rows, equal GeoJSON, zero differing DTM
  cells and zero differing CHM cells;
- its ordered-COPC and ordered-LAZ DTM/CHM TIFFs were byte-identical;
- a synthetic differential fixture with deliberately different primary, SAT
  and FM labels produced byte-identical ordered-LAZ and ordered-COPC outputs
  for all 15 promoted artifacts;
- the canonical dataset-2160 COPC contained a complete unique point-index
  range and matching per-dimension fingerprints for all 68,302,459 points.

Under the same 10-CPU/30-GiB profile, dataset 2160 analysis took 405.399 s from
canonical COPC and 478.983 s from ordered LAZ, a 15.4% COPC analysis speedup.
The COPC run peaked at 12,356.855 MiB cgroup memory. COPC creation is a separate
one-time preprocessing cost and is not included in that runtime comparison.

The prior production output for dataset 2160 was generated directly from
spatial COPC order and therefore differed from the reference ordering: SAT had
14 tile-result and 164 diagnostic value differences; FM had 12 tile-result and
148 diagnostic value differences; DTM differed in 199 cells and CHM in 55
cells. All those differences became zero when canonical COPC output was
compared with the ordered source-LAZ oracle. This demonstrates why
`OriginalPointIndex` is required and why the older output is not the oracle.

### Tests added or extended

- Canonical ExtraByte/order conversion and streaming fingerprint validation.
- Ordered-LAZ versus COPC point-order comparison.
- Zero-tolerance CSV, diagnostic, GeoJSON, DTM and CHM comparators.
- Cohort manifests covering `valid`, `pending` and `valid_updated` inputs.
- Three-dimension synthetic differential acceptance.
- Fine-coordinate DTM failure and guarded fallback regression.
- Missing primary with present SAT/FM behavior.
- Selector-pressure regression with many unrelated ExtraBytes.
- Existing failed-dataset, memory, raster-layout and Julia-oracle regressions.

### Known constraints

- The canonical COPC conversion is mandatory for scientific COPC parity;
  arbitrary COPCs without `OriginalPointIndex` are rejected.
- Conversion temporarily needs space for an indexed LAZ and the resulting
  COPC.
- COPC conversion and ForestStructure analysis should run sequentially inside
  each resource slot so their hard memory limits do not overlap.
- R/lidR cannot represent one file with more than 2,147,483,647 points.
- Exact parity is guaranteed only for the pinned dependency set recorded in
  run provenance.

### Repository and release cleanup

- Added the unchanged reference script to `reference/` so comparisons no
  longer depend on an external attachment.
- Consolidated superseded dated validation notes into this changelog.
- Removed obsolete local image names and stale readiness conclusions from
  current usage documentation.
- Retained historical Git tags and commits as immutable provenance; no
  published release was deleted or rewritten.
- The existing `v0.1.0` release is historical and must not be used for new
  scientific processing. A new release should be created from the reviewed
  merge commit and identified by its Git SHA/container digest.
