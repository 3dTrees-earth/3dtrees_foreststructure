# Performance benchmark

The benchmark drives the public container CLI with deterministic synthetic,
segmented point clouds. It records point/tile counts, every parameter, phase
wall times, effective threads, and the R process's peak RSS (`VmHWM`).

```bash
docker build -t 3dtrees-foreststructure:benchmark .
bash benchmarks/run_benchmark.sh \
  3dtrees-foreststructure:benchmark \
  /tmp/foreststructure-profile \
  1
```

To compare a candidate with a preserved baseline image, run both images against
the same work directory and then execute `benchmarks/compare_runs.R` inside
either image. The comparator requires equal CSV and diagnostic values, matching
tile geometries, and equal DTM/CHM geometry, CRS, and cell values within
absolute/relative tolerance `1e-9`.

## 2026-07-20 results

Both runs used one lidR thread and the documented scientific defaults.

| Fixture | Baseline | Optimized | Change | Peak RSS change |
| --- | ---: | ---: | ---: | ---: |
| 50,000 points / 9 tiles | 4.248 s | 2.897 s | -31.8% | 414.2 → 409.8 MiB |
| 500,000 points / 36 tiles | 17.713 s | 15.112 s | -14.7% | 506.1 → 500.7 MiB |

The accepted changes are:

- stop the exact offset search when it reaches the AOI-area upper bound; and
- read only XYZ plus extra byte zero during the global segment pass when the
  selected Instance Dimension is the first extra byte, falling back to all
  dimensions for later aliases.

The complete scientific differential passed at `1e-9`, and the full container
acceptance matrix passed afterward. Raw summary values are committed in
`benchmarks/results/2026-07-20.csv`.

## Evaluated alternatives

- Temporary symlinked and genuine adjacent `.lax` indices did not improve tile
  reads in this lidR/rlas path; the large run remained 17.9–18.0 s.
- Batching many grid candidates into fewer GEOS calls did not improve the grid
  phase and slightly increased total time.
- Four lidR threads were effectively neutral on these fixtures (17.579 s versus
  17.713 s at one thread) and slightly increased observed peak RSS.
- An explicit phase-boundary `gc()` added about 0.2 s and cannot reduce the
  already-recorded high-water mark, so it was removed. The obsolete accumulated
  segment tables are still dereferenced before tile processing.
- Combining the global DTM and segment passes was not attempted: they require
  different classification/aggregation semantics, and holding a shared raw
  cloud would weaken the streaming memory contract. Result assembly was also
  not targeted because it already uses `lapply`/`rbindlist` and measured below
  one percent of the large run.

## Runtime guidance

- Keep `--grid-search-step 0.5` for strict method equivalence. A coarser value
  remains an optimized search but deliberately changes the candidate lattice.
- Set `--threads` to the CPUs actually allocated by the scheduler. One to four
  threads produced similar results here; do not request excess cores expecting
  linear speedup.
- Small clouds are dominated by fixed DTM and grid setup. Larger clouds are
  dominated by per-tile point processing, so runtime grows with both point and
  valid-tile counts.
