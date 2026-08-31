# ForestStructure Docker images

This document distinguishes the scientific reference, the image used by the
currently running `valid_updated` workers, and the ordered-COPC optimized
image. These are related implementations, but they are not interchangeable
inputs or releases.

## Operational snapshot

The following facts were read from the eight active ForestStructure containers
on 2026-08-31. This is a dated operational snapshot, not a declaration that a
particular container will still be running later.

| Property | Observed value |
| --- | --- |
| Active workers | 8 |
| Short image alias | `3dtrees-foreststructure:direct` |
| Local Docker image ID | `sha256:8b7b6e4a0a5bbbe1f3fd0422ee5d05817994158a4c3de3f066311f6c41fc6df8` |
| Image source revision | `11d56311fc340421d09d6d448d218f2130d02191` |
| Entrypoint | `Rscript /opt/foreststructure/run_julia_memory_safe.R` |
| Input | One original, non-COPC LAS/LAZ and one Audit GeoJSON |
| Instance dimensions | `PredInstance`, `PredInstance_SAT`, `PredInstance_FM` |
| CPU limit | 12 CPUs per worker |
| Docker memory/swap limit | 37 GiB per worker |
| Internal memory budget | 32 GiB per worker |
| LAScatalog workers | 2 per container |
| lidR/thread allowance | 12 per container |
| Restart policy | `no`; a stopped container does not restart automatically |

The image label allows an internal budget as high as 70 GiB, but the running
containers deliberately pass `--memory-budget-gib 32`. The 37 GiB Docker
limit is the actual hard ceiling. The difference leaves approximately 5 GiB
for the R runtime, libraries, temporary buffers and accounting overhead.

The running image reads the original LAZ directly and explicitly rejects a
`.copc.laz` input. This keeps source record order visible to Julia-compatible
tie-breaking, apex selection and PCA operations, but it does not provide COPC
spatial pruning. It is the direct-LAZ baseline currently generating the
`valid_updated` results.

The image is a local operational build. Its local image ID is not a portable
registry digest and should not be treated as a published release identifier.
The source can be inspected at revision `11d5631`; rebuild it from a separate
clean checkout or Git worktree if historical reproduction is required.

## Generic command matching the running profile

Dataset paths and identifiers are intentionally placeholders. The command
documents the runtime contract without committing machine-specific mounts.

```bash
docker run --rm --network none \
  --cpus 12 \
  --memory 37g \
  --memory-swap 37g \
  --env FORESTSTRUCTURE_THREADS=12 \
  --env FORESTSTRUCTURE_CATALOG_WORKERS=2 \
  --volume /local/input:/in:ro \
  --volume /local/output:/out \
  --volume /local/ssd-work:/work \
  3dtrees-foreststructure:direct \
  --point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id 150 \
  --output-dir /out \
  --temp-dir /work \
  --memory-budget-gib 32 \
  --instance-dimension PredInstance \
  --instance-dimension PredInstance_SAT \
  --instance-dimension PredInstance_FM
```

`--rm` and the absence of `--restart` reproduce the observed lifecycle: the
container is removed after a normal stop and Docker does not restart it after
a failure or daemon restart.

## Three-way comparison

| Concern | Original Julia script | Currently running direct-LAZ image | Ordered-COPC optimized image |
| --- | --- | --- | --- |
| Identity | `reference/Indices_Final_run.R`, SHA-256 `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226` | Image revision `11d5631`; local image ID `8b7b6e4a0a5b…` | Source commit `7ea0302`; validated local image ID `cfc7948984ab…` |
| Intended role | Immutable scientific reference | Current `valid_updated` baseline processing | Validated replacement candidate after review and immutable publication |
| Entrypoint | Interactive/local R script | `run_julia_memory_safe.R` | `run_julia_memory_safe.R` |
| Input discovery | Recursively scans configured TLS/MLS/ULS directories | Exactly one original LAS/LAZ per container | Exactly one original LAS/LAZ or one canonical ordered COPC per container |
| COPC support | None | Explicitly rejected | Required for the optimized spatial-streaming path |
| Point-order behavior | Uses original LAS/LAZ record order | Uses original LAS/LAZ record order directly | Spatially reads COPC chunks, then restores source order with `OriginalPointIndex` before every scientific operation |
| Spatial access | LAScatalog chunks over source LAS/LAZ plus per-tile reads | LAScatalog chunks over source LAS/LAZ | COPC spatial pruning for DTM, CHM, segmentation and tile reads |
| Instance dimensions | `PredInstance` only | Primary, SAT and FM processed independently | Primary, SAT and FM processed independently |
| AOI/grid | Local configured input and optimized 20 m grid | Required Audit GeoJSON converted to a deterministic GeoPackage | Same conversion and grid behavior as the direct-LAZ image |
| DTM/CHM | Global catalog DTM; per-tile CHM metrics | Disk-backed, bounded global DTM/CHM processing | Same scientific calculations, with ordered spatial COPC reads and guarded fine-coordinate DTM fallback |
| Memory control | No Docker limit or internal memory guard in the script | Observed profile: 12 CPU, 37 GiB hard, 32 GiB internal, 2 catalog workers | Validated profile: 10 CPU, 30 GiB hard, 25 GiB internal, 1 catalog worker |
| Outputs | Combined `results.csv` and `segment_diagnostics.csv` | Dataset/dimension-specific CSV, diagnostics and GeoJSON plus shared DTM, CHM, PNG and run metadata | Same artifact contract, staged validation and atomic promotion |
| Scientific parity evidence | Defines the expected calculations | Produces the direct-LAZ `valid_updated` baseline | 36 real datasets matched `valid_updated` exactly for primary results; dataset 2160 matched SAT/FM exactly; all 15 synthetic three-dimension artifacts were byte-identical |
| Main limitation | Workstation paths, no bounded container contract and only primary segmentation | Reads original LAZ repeatedly; no COPC spatial pruning; no automatic restart | Requires one-time canonical COPC conversion and a complete unique `OriginalPointIndex` |
| Release status | Reference file, not an image | Historical local operational image currently running | Validated local candidate; publish by immutable Git SHA/registry digest after merge |

The optimized local image alias `3dtrees-foreststructure:copc` has local Docker
image ID
`sha256:cfc7948984ab28f8708741d69bf6c7c9a6ed8d7f3eb3377a32db0e0509a98f44`.
The five files installed under `/opt/foreststructure` were hash-checked against
commit `7ea0302` on 2026-08-31 and matched exactly. The tag is still a local
validation name, not a registry release.

## Optimized image build and run

Build the ordered-COPC implementation from the reviewed source:

```bash
make build-julia-memory-safe \
  JULIA_MEMORY_SAFE_IMAGE=3dtrees-foreststructure:copc-local
```

Create the canonical COPC once, then run the 10-CPU/30-GiB profile. Complete
commands and validation checks are maintained in
[`JULIA_MEMORY_SAFE.md`](JULIA_MEMORY_SAFE.md). The conversion preserves every
source point and adds the source record position as `OriginalPointIndex`.
During analysis, the original companion is optional and is used only for
header-identity validation; it is never the LAScatalog data source.

## Which implementation should be used?

- Use the original script only as the immutable scientific oracle.
- Leave already-running direct-LAZ workers on their recorded image unless an
  operational migration is explicitly approved.
- Use the ordered-COPC implementation for new controlled validation and, after
  merge/publication, for replacement production workers.
- Never pass an arbitrary COPC to the optimized image. Rebuild it with
  `tests/build_original_order_copc.sh` so `OriginalPointIndex` and the three
  supported instance dimensions are validated.
