# Performance benchmarks

The benchmark suite drives the public container CLI and records point/tile
counts, scientific parameters, phase wall times, effective threads, R-process
peak RSS (`VmHWM`) and cgroup-wide peak memory. Small deterministic fixtures
remain useful for local profiling; the current release reference is the
production-scale dataset 107 comparison below.

```bash
docker build -t 3dtrees-foreststructure:benchmark .
bash benchmarks/run_benchmark.sh \
  3dtrees-foreststructure:benchmark \
  /tmp/foreststructure-profile \
  1
```

To compare two synthetic runs, execute `benchmarks/compare_runs.R` inside
either image. The comparator requires equal CSV and diagnostic values, matching
tile geometries, and equal DTM/CHM geometry, CRS, and cell values within
absolute/relative tolerance `1e-9`.

## Current result: dataset 107, 2026-08-31

Dataset 107 is a 156,184,097-point cloud covering 25 complete analysis tiles.
The candidate first converted the 2,768,471,261-byte ordered LAZ into a
4,284,572,283-byte COPC with a zero-based `OriginalPointIndex`, then used COPC
spatial streaming while restoring original record order within every chunk.

| Measurement | Ordered LAZ baseline | Indexed COPC candidate | Change |
| --- | ---: | ---: | ---: |
| CPUs / LAScatalog workers | 12 / 2 | 10 / 1 | fewer resources |
| Container / internal memory limit | 37 / 32 GiB | 30 / 25 GiB | lower limits |
| Analysis runtime | 6,217.955 s | 1,996.875 s | -67.9% (3.11x) |
| Cgroup peak memory | 29,023.309 MiB | 17,767.770 MiB | -38.8% |
| DTM | 864.246 s | 893.619 s | +3.4% |
| CHM | 781.908 s | 370.590 s | -52.6% |
| Segmentation | 821.788 s | 389.765 s | -52.6% |
| Tile metrics | 3,748.338 s | 341.213 s | -90.9% |

COPC construction plus streaming point/index validation took 215.656 seconds.
The complete candidate benchmark—from COPC construction through all output
comparisons—took 2,234.749 seconds (37m 14.749s), still 64.1% below the
baseline analysis runtime.

The indexed COPC passed exact header, point-count, index-range and dual-64-bit
tuple-fingerprint validation over all points. Scientific comparison against
`valid_updated` then passed at zero tolerance:

- 25 result rows with zero differing values;
- 900 segment-diagnostic rows with zero differing values;
- identical tile GeoJSON after excluding only the source-file metadata field;
- 14,632 DTM cells with identical geometry, masks and values; and
- 57,810 CHM cells with identical geometry, masks and values.

The candidate image alias was `3dtrees-foreststructure:copc`
(`sha256:cfc7948984ab28f8708741d69bf6c7c9a6ed8d7f3eb3377a32db0e0509a98f44`).
Raw summary values are committed in
`benchmarks/results/2026-08-31-dataset107.csv`. The large COPC, rasters and
verbose logs remain external benchmark artifacts and are intentionally not
stored in Git.
