#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="${FORESTSTRUCTURE_IMAGE:-3dtrees-foreststructure:test}"
input_dir="$(mktemp -d)"
results_dir="$(mktemp -d)"
trap 'rm -rf "${input_dir}" "${results_dir}"' EXIT

docker build --tag "${image_name}" "${repo_dir}"
docker run --rm --network none \
  --user "$(id -u):$(id -g)" \
  --entrypoint Rscript \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${input_dir}:/generated" \
  "${image_name}" \
  /tests/generate_fixture.R \
  /generated/point_cloud.laz \
  /generated/aoi_with_exclusion.gpkg

run_case() {
  local name="$1"
  local aoi_path="$2"
  local expected_tiles="$3"
  local output_dir="${results_dir}/${name}"
  mkdir -p "${output_dir}"

  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --volume "${repo_dir}/tests/fixtures:/fixtures:ro" \
    --volume "${input_dir}:/in:ro" \
    --volume "${output_dir}:/out" \
    "${image_name}" \
    --point-cloud /in/point_cloud.laz \
    --aoi "${aoi_path}" \
    --output-dir /out

  python - "${output_dir}" "${expected_tiles}" <<'PY'
import csv
import json
import pathlib
import sys

output_dir = pathlib.Path(sys.argv[1])
expected_tiles = int(sys.argv[2])
csv_path = output_dir / "forest_structure_tiles.csv"
geojson_path = output_dir / "forest_structure_tiles.geojson"
png_path = output_dir / "forest_structure_tiles.png"
dtm_path = output_dir / "forest_structure_dtm.tif"
chm_dir = output_dir / "chm"

if not csv_path.is_file():
    raise SystemExit(f"missing tile CSV: {csv_path}")

with csv_path.open(newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle)
    rows = list(reader)
    fieldnames = reader.fieldnames or []

required = {
    "point_cloud",
    "tile_id",
    "tile_xmin",
    "tile_ymin",
    "edge_tile",
    "vox_filled",
    "vox_total",
    "veg_density",
    "zsd",
    "zskew",
    "zkurt",
    "zq90",
    "box_dim_fixed",
    "vci",
    "rumple",
    "gap_fraction",
    "chm_sd",
    "chm_cv",
    "height_max",
    "height_mean",
}
missing = required.difference(fieldnames)
if missing:
    raise SystemExit(f"tile CSV missing columns: {sorted(missing)}")

if len(rows) != expected_tiles:
    raise SystemExit(
        f"expected {expected_tiles} complete Analysis Tiles, found {len(rows)}"
    )

expected_ids = [str(index) for index in range(1, expected_tiles + 1)]
if [row["tile_id"] for row in rows] != expected_ids:
    raise SystemExit("tile IDs are not deterministic")

if not geojson_path.is_file():
    raise SystemExit(f"missing tile GeoJSON: {geojson_path}")
with geojson_path.open(encoding="utf-8") as handle:
    geojson = json.load(handle)
features = geojson.get("features", [])
if len(features) != expected_tiles:
    raise SystemExit("tile GeoJSON feature count does not match the tile CSV")
if [str(feature["properties"]["tile_id"]) for feature in features] != expected_ids:
    raise SystemExit("tile GeoJSON IDs do not match the tile CSV")

if png_path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"missing or invalid PNG: {png_path}")
if dtm_path.read_bytes()[:4] not in (b"II*\x00", b"MM\x00*"):
    raise SystemExit(f"missing or invalid DTM GeoTIFF: {dtm_path}")

chms = sorted(chm_dir.glob("tile_*_chm.tif")) if chm_dir.is_dir() else []
if len(chms) != expected_tiles:
    raise SystemExit(f"expected {expected_tiles} CHMs, found {len(chms)}")
PY
}

run_case inclusion_only /fixtures/aoi.geojson 4
run_case geojson_exclusion /fixtures/aoi_with_exclusion.geojson 3
run_case gpkg_exclusion /in/aoi_with_exclusion.gpkg 3
run_case zero_tiles /fixtures/aoi_zero_tiles.geojson 0

docker run --rm --network none \
  --user "$(id -u):$(id -g)" \
  --entrypoint Rscript \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${results_dir}:/results:ro" \
  "${image_name}" \
  /tests/verify_rasters.R /results
