# Dataset 150 regression oracle

The two CSVs are the upstream outputs supplied for dataset 150. They are stored
with LF line endings; their row content is unchanged from the supplied CRLF
files.

Original supplied-file SHA-256:

- `150_results.csv`: `b9c8f72b38e76f9c60dc94ef5a8d18809e5b4ce33f746fece4f156c381335eb9`
- `150_segment_diagnostics.csv`: `d7dd99f4ac48953e5afbe416aae616d153bde8c72d5efb9917d4bdcf14dce77d`

`150_upstream_tiles.geojson` is the union of the 146 exact 20 m tile
footprints recorded by the upstream result. It is intentionally separate from
the current production Audit AOI, which represents a different footprint and
produces 82 valid tiles.

The point cloud is not committed. Run the regression with the original
`80.laz` through `make test-dataset150`. Its SHA-256 is
`d767997ce5868a98fb9dc0a688cb3d300fc8b7cee45571eadcf9b6102c9f9789`.
The test rejects a COPC or any other LAZ and compares every scientific output
cell exactly, without tolerances.
