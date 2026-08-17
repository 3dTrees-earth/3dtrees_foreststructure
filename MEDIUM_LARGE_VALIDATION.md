# Medium-large Julia equivalence validation

## Scope

This validation pass compares the Julia-faithful memory-safe candidate with
Julia Gäßler's unchanged thesis script on five additional single-LAZ datasets.
It is a zero-tolerance source-of-truth check, not a scientific-tolerance check.

Julia source of truth:

- file: `Indices_Final_run.R` supplied by Julia;
- SHA-256: `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`;
- input: the original `.laz`, not a COPC;
- AOI: the dataset GeoJSON converted once to GeoPackage and supplied to both
  runs;
- Julia's source was not edited.

Candidate:

- image: `3dtrees-foreststructure:julia-memory-safe-dataset150-final3`;
- image ID:
  `sha256:26b76ef4a6f014fedfa5c08ad0616e869761d5dbea0b78fc6bd3bd43dcdcfb45`;
- limit: 20 CPUs, 75 GiB RAM, no extra swap, network disabled;
- inputs mounted read-only and outputs written under the validation root;
- at most two validation containers ran concurrently.

The gate requires identical tile and segment CSV headers, row order and string
values; identical DTM geometry, CRS, NA mask and cell values; successful
container exit without OOM; and complete candidate artifacts/provenance. A
single fourth-decimal CSV difference therefore fails this gate.

## Dataset selection

All five datasets were non-archived and eligible, had one original LAZ, an AOI,
`ReturnNumber`, `NumberOfReturns`, and `PredInstance`. The set spans TLS, MLS
and ULS, different ExtraBytes ordinals, and approximately 59-230 million
points.

| Dataset | Platform | Points | LAZ size | AOI tiles | PredInstance ordinal |
| ---: | :--- | ---: | ---: | ---: | ---: |
| 926 | TLS | 59,128,560 | 0.570 GB | 2 | 3 |
| 970 | MLS | 97,236,733 | 0.855 GB | 3 | 2 |
| 931 | TLS | 91,654,270 | 1.152 GB | 3 | 3 |
| 1781 | ULS | 145,916,689 | 1.607 GB | n/a | present |
| 2062 | MLS | 230,242,672 | 2.317 GB | 3 | 2 |

## Initial results before corrections

| Dataset | Result | Tile CSV | Segment CSV | DTM | Peak candidate memory | Evidence |
| ---: | :--- | :--- | :--- | :--- | ---: | :--- |
| 926 | **valid after harness review** | 2 rows, byte-identical | 185 rows, byte-identical | 2,601 cells, exact | 7.72 GiB cgroup | `dataset926_WEecodkO` |
| 931 | **valid** | 3 rows, byte-identical | 174 rows, byte-identical | 2,601 cells, exact | 13.82 GiB cgroup | `dataset931_HVqgFkyN` |
| 970 | **invalid at zero tolerance** | 3 rows, byte-identical | 1/18,258 values differs | geometry and 578 cells differ | 12.57 GiB cgroup | `dataset970_E7iOhgnT` |
| 1781 | **not executed: validation-gate bug** | not run | not run | not run | n/a | `dataset1781_G0ICstDb` |
| 2062 | **invalid at zero tolerance** | 3 rows, byte-identical | 6/8,058 values differ | geometry and 783 cells differ | 21.11 GiB cgroup | `dataset2062_ZfqSNHmh` |

The preserved evidence root is:

```text
/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/medium_large/
```

### Dataset 926

Both containers exited 0 without OOM. The CSVs are byte-identical and the DTM
is equal cell-for-cell. The original harness nevertheless wrote `failed` after
the scientific checks because `jsonlite` serializes a one-element
`processed_instance_dimensions` value as a string, while the post-check
expected an array. The assertion now accepts both valid JSON shapes. The run
was not repeated; review of its run manifest confirms `status: valid`, the
requested and processed `PredInstance`, selector `xyz3`, the source hash and
point count. This is a harness-only bookkeeping failure, so the scientific run
is valid.

Candidate timing was 542.366 seconds; cgroup peak memory was 7,719.3 MiB.

### Dataset 931

The complete gate passed: 3 tile rows, 174 segment rows and 2,601 DTM cells
were exactly equal. Both containers exited 0 without OOM. Candidate timing was
804.989 seconds and cgroup peak memory was 14,156.3 MiB.

### Dataset 970

Both analyses completed successfully without OOM, but strict equivalence
failed:

- all 3 tile rows and 34 columns are byte-identical;
- the segment tables have the same 1,074 rows and 17 columns;
- exactly one value differs: row 944, `PredInstance=1292`, `pc_ext2` is
  `3.833` in Julia and `3.8329` in the candidate (absolute difference
  `0.0001`);
- Julia's DTM is 240 x 241 with extent `[-1,239] x [-1,240]` and no CRS;
- the candidate DTM is 239 x 240 with extent `[0,239] x [0,240]` and is
  incorrectly labelled EPSG:4326;
- over the shared extent, the NA mask is equal and 578 of 44,976 populated
  cells differ only at floating-point epsilon, with maximum absolute
  difference `1.776357e-15`.

The candidate's disk-backed DTM publication currently trims Julia/lidR's
one-cell negative border for this CRS-less local point cloud and assigns a CRS
that the source does not have. The tiny cell differences can cross the
fourth-decimal rounding boundary after normalization, voxelization and PCA,
which explains the one `pc_ext2` difference. This is a real correctness issue
under the Julia-exact acceptance criterion and must be corrected before a
cohort run.

Candidate timing was 2,455.215 seconds and cgroup peak memory was 12,868.4 MiB.

#### Dataset 970 causal follow-up

The source header was rechecked and contains no CRS. A focused publication
regression also reproduced the false EPSG:4326 assignment without an AOI or a
CRS-bearing point cloud: this `terra`/GDAL runtime inferred WGS84 when a
CRS-less raster happened to fit longitude/latitude bounds. The publication
path now treats the LAS/LAZ header as authoritative and explicitly removes
GDAL projection metadata from final DTM and CHM files when the source CRS is
missing. Tile geometries likewise remain CRS-less. This is a metadata-only
correction; it does not change coordinates or raster cells. Applying the
alignment helper to a temporary copy of dataset 970's candidate DTM changed
the GDAL CRS state from present to absent while its band checksum remained
`60682` before and after.

The `pc_ext2` difference was then tested counterfactually for the original
3,478 points of `PredInstance=1292`. The same normalization, 0.2 m
voxelization and PCA calculation was run twice, changing only the DTM:

| Check | Julia DTM | Candidate DTM |
| :--- | ---: | ---: |
| Unique voxels | 1,321 | 1,321 |
| Raw `pc_ext2` | 3.8330393111565182 | 3.8328702777342607 |
| Rounded `pc_ext2` | 3.8330 | 3.8329 |

The normalized point heights differ by at most `0.0001`, which is the source
LAS Z scale. Although the underlying shared DTM cells differ only at floating
point epsilon, height normalization quantizes back to that LAS scale. One
voxel coordinate is consequently present only in the Julia result and one
only in the candidate result, while the total voxel count remains unchanged.
That voxel-set change produces the observed PCA difference. This proves that
the row-944 scientific difference is caused by the DTM numerical/publication
path, not by the incorrect CRS label. Clearing the CRS fixes metadata but does
not by itself make dataset 970 Julia-exact.

#### Exact rounding root cause

The DTM difference was traced to chunk ordering, not PTD/TIN, GeoTIFF
precision, CRS handling, border coverage, or the final CSV formatting.
Julia's `catalog_apply(..., automerge = TRUE)` keeps LAScatalog's numeric chunk
order. The disk-backed candidate instead applies `sort()` to chunk file paths,
which is lexical rather than numeric:

```text
Julia/catalog:  dtm_1, dtm_2, ..., dtm_9, dtm_10, ...
Candidate:      dtm_1, dtm_10, ..., dtm_16, dtm_2, ..., dtm_9
```

The probe cell used by `PredInstance=1292` is covered by four buffered chunk
surfaces. Their values are identical in both implementations:

| Chunk | Ground value |
| ---: | ---: |
| 5 | 5.4698000000000002 |
| 6 | 5.319 |
| 9 | 5.319 |
| 10 | 5.3012000000000006 |

Floating-point addition is not associative. Averaging in Julia's contributor
order `5, 6, 9, 10` produces `5.3522500000000006`; the candidate's lexical
order `10, 5, 6, 9` produces the adjacent representable double
`5.3522499999999997`.

A full 16-chunk DTM-only rerun with the original candidate image reproduced
the preserved candidate value. Reassembling the same saved chunk rasters in
numeric catalog order produced zero differing populated cells and an identical
NA mask against Julia over the complete shared grid. Lexical order reproduced
all 578 differing cells, with maximum absolute difference
`1.7763568394002505e-15`.

`normalize_height()` subtracts the DTM and calls lidR's `fast_quantization()`
using the source LAS Z scale of `0.0001`. For the one point that changes the
segment voxel set:

```text
source Z:                  16.3522
Julia ground:               5.3522500000000006
candidate ground:           5.3522499999999997
Julia pre-quantized Z:      10.999949999999998
candidate pre-quantized Z:  10.99995
Julia quantized Z:          10.9999  -> voxel floor(Z / 0.2) = 54
candidate quantized Z:      11.0000  -> voxel floor(Z / 0.2) = 55
```

Across the 3,478 points of the segment, 88 read a ground value with an
epsilon-scale difference, 29 differ after LAS-scale quantization, and exactly
one crosses a 0.2 m voxel boundary. PCA is therefore run on a genuinely
different voxel set. The final `round(pc_ext2, 4)` only exposes the already
different PCA extents (`3.833039...` versus `3.832870...`); it did not create
the regression.

The lexical ordering entered with the disk-backed DTM path in commit
`01a472f` through sorted `list.files()` output and remained explicit as
`sort(unlist(results))` in commit `3467eb9`. The existing synthetic raster
test used only two exactly representable values, so it could not detect
non-associative overlap means or the `dtm_10` ordering transition.

The correction is to preserve the ordered `catalog_apply()` result list
exactly and cover a greater-than-nine-chunk non-associative overlap in the
regression suite. That correction and its fresh revalidation are documented
below.

## Ordering correction revalidation

`write_global_dtm()` now passes `results` through
`complete_chunk_raster_paths(results, "DTM")`. This keeps the numeric catalog
order and retains the existing completeness/file-existence validation; it
removes only the lexical `sort()`.

The regression uses 16 `FLT8S` chunk rasters and the four real order-sensitive
values from dataset 970. Before the production edit, the test reproduced the
two adjacent doubles and failed because `write_global_dtm()` still sorted the
paths. After the edit, numeric order yields `5.3522500000000006`, lexical order
yields `5.3522499999999997`, and the production call-site assertion passes.
The focused runtime/failed-dataset tests and the complete synthetic acceptance
suite also pass.

Exact image used for both fresh full runs:

- tag:
  `3dtrees-foreststructure:julia-memory-safe-order-fixed-20260817`;
- image ID:
  `sha256:325ece1e7072055858a340a3ea544a034b8149382744d638ebfe1c1684878fe4`;
- OCI revision: `working-tree-dtm-catalog-order-20260817`;
- OCI version: `julia-memory-safe-order-fixed-20260817`;
- base image ID:
  `sha256:3eee1d12654002a5cbb4bcc0bca13fcf93622307b1a4fe899e35ce9393a3dac9`;
- lidR 4.3.2;
- local-only image, so no registry `RepoDigest` exists.

Both validations reran from the original LAZ and AOI GeoJSON, using 20 CPUs,
75 GiB RAM/no extra swap, disabled networking, read-only inputs and the `kg281`
UID/GID. The preserved evidence root is:

```text
/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/order_fix_20260817/
```

| Dataset | Exit/OOM | Tile CSV | Segment CSV | Shared DTM | Time | Cgroup peak |
| ---: | :--- | :--- | :--- | :--- | ---: | ---: |
| 970 | 0 / false | 3 rows, byte-identical | 1,074 rows, byte-identical | 57,360 cells, 0 differences | 2,478.100 s | 13,127.238 MiB |
| 2062 | 0 / false | 3 rows, byte-identical | 474 rows, byte-identical | 60,786 cells, 0 differences | 8,440.159 s | 24,609.184 MiB |

Dataset 970's former row-944 `pc_ext2` difference is gone. Its tile and
segment CSV SHA-256 values now match Julia exactly:
`ab844b527e5c106cb9944c971b235d64ecd204d1659b6f3366691f0526c0ae48`
and
`227cc4843569da3176c765371d613100f7bfa8c73b0c8faa937b5a4443098a8f`.
All 44,976 jointly populated DTM cells match at zero tolerance, the NA mask is
identical, and both rasters are correctly CRS-less.

All six former dataset-2062 segment values are also gone. Its tile and segment
CSV SHA-256 values now match Julia exactly:
`0666c7e78ede80d97b927fe808d3395826c136cac62a455b1046507dc51b0860`
and
`28ca3998f00a13bcdb66055b970b46db14c320fd9566d1a256903759804b7bff`.
All 46,110 jointly populated DTM cells match at zero tolerance, the NA mask is
identical, and both rasters are correctly CRS-less.

This resolves the ordering-caused scientific mismatch. It does not hide the
separate grid-border difference: Julia still has a negative one-cell border
(`240 x 241` versus `239 x 240` for 970; `308 x 199` versus `307 x 198` for
2062). Therefore the complete shared grid is exact, but full DTM geometry is
not yet exact. The order-fix runs did not change source LAZ, AOI, or preserved
Julia-oracle artifacts.

#### Dataset 970 pinned-lidR layout follow-up

The publication crop now obtains its target extent from the same pinned lidR
4.3.2 `raster_layout()` implementation called by Julia's unchanged
`rasterize_terrain()` path. It also fails rather than silently padding if the
disk-backed chunk mosaic does not contain that complete layout. A focused
exact-grid-boundary regression failed before this correction and passes after
it.

Dataset 970 was freshly recomputed from the original `5211.laz` with two
LAScatalog workers, 20 CPUs and a 75 GiB container limit. The previously
captured Julia oracle was reused only after verifying the source LAZ, AOI and
unchanged Julia-script hashes and its successful exit/OOM state. The corrected
candidate passed every strict gate:

- DTM geometry is identical: 240 columns x 241 rows, extent
  `[-1,239] x [-1,240]`, 1 m resolution and no CRS;
- all 57,840 DTM cells, including 44,993 populated cells, are equal at zero
  tolerance;
- all three tile rows and all 1,074 segment rows are byte-identical to Julia;
- the run exited 0 without OOM, completed in 1,419.836 seconds and peaked at
  22,267.914 MiB cgroup memory.

Validation image:
`3dtrees-foreststructure:julia-memory-safe-lidr-layout-dataset970-20260817`,
image ID
`sha256:5d16a6b85ed1bbc0a0f8d1ddbaf331aa8aead1be95f48f745edaa13a7465a831`.
Evidence is retained under
`/mnt/ssds/kg281/_foreststructure_julia_memory_safe_validation/lidr_layout_20260817/dataset970_EWan8i5G`.
Dataset 2062 has not yet been rerun with this layout correction, so its former
border result remains historical rather than newly validated.

### Dataset 1781

Neither scientific analysis ran. GeoJSON to GeoPackage conversion preserved
the MultiPolygon topologically:

- `st_equals` is true;
- area and bounds are identical;
- Hausdorff distance is zero;
- geometry type, part count and coordinate-row count are unchanged.

GDAL only rotated polygon-ring starting vertices. The conversion gate uses
order-sensitive `st_equals_exact`/WKB semantics and rejected that harmless
serialization change. The converter should compare canonicalized rings, or
combine topological equality with coordinate-set, bounds, area and generated
tile-grid checks, while still rejecting actual coordinate changes. The dataset
was flagged and not retried.

### Dataset 2062

Both analyses completed successfully without OOM. Julia and the candidate both
found 474 segments, accepted 454 trees and rejected 20. All 3 tile rows and 34
columns are byte-identical. The segment tables have the same 474 rows and 17
columns, but 6 values differ in 3 rows:

| PredInstance | Column | Julia | Candidate | Absolute difference |
| ---: | :--- | ---: | ---: | ---: |
| 254 | `pc_ext2` | 9.0213 | 9.0212 | 0.0001 |
| 254 | `pc_ext3` | 7.0491 | 7.0492 | 0.0001 |
| 255 | `n_vox` | 3,258 | 3,259 | 1 |
| 255 | `pc_ext2` | 6.1276 | 6.1277 | 0.0001 |
| 255 | `pc_ext3` | 4.9385 | 4.9387 | 0.0002 |
| 316 | `apex_z` | 18.2496 | 18.2497 | 0.0001 |

The DTM reproduces the same issue seen on dataset 970:

- Julia: 308 columns x 199 rows, extent `[-1,307] x [-1,198]`, no CRS;
- candidate: 307 columns x 198 rows, extent `[0,307] x [0,198]`, incorrectly
  labelled EPSG:4326;
- on the shared extent, the NA mask is identical;
- 783 of 46,110 jointly populated cells differ at floating-point scale;
- maximum absolute shared-cell difference is `1.4210854715202004e-14`.

Those tiny normalized-height changes cross fourth-decimal rounding and, for
one voxel, a `floor(Z / 0.2)` boundary. This produces the six segment-table
differences above even though the tile CSV is byte-identical.

Candidate timing was 8,381.554 seconds. Parent peak RSS was 21,611.7 MiB,
cgroup peak memory was 21,617.0 MiB, and observed temporary-disk peak was
143.1 MiB. This proves the 230,242,672-point run is memory-safe under 75 GiB,
but it does **not** pass Julia-exact scientific validation.

## Readiness conclusion

The ordering-corrected candidate now reproduces Julia's tile and segment CSVs
byte-for-byte for both previously failing scientific canaries, datasets 970
and 2062. Their complete shared DTM grids are also exact, and the false CRS
assignment is gone. The identified lexical-order scientific regression is
therefore resolved.

The pinned-lidR publication-layout correction now reproduces Julia's complete
DTM geometry and values for dataset 970. Dataset 2062 still requires a fresh
full rerun with that correction, and dataset 1781 still exposes an overly
strict AOI ring-order validation gate before analysis. The candidate is
therefore still **not yet approved for all single-file datasets**. These are
separate validation items and must not be conflated with the fixed
floating-point ordering path. No source LAZ, AOI or production ForestStructure
output was changed by this validation pass.
