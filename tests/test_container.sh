#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="${FORESTSTRUCTURE_IMAGE:-3dtrees-foreststructure:test}"
input_dir="$(mktemp -d)"
output_dir="$(mktemp -d)"
trap 'rm -rf "${input_dir}" "${output_dir}"' EXIT

docker build --tag "${image_name}" "${repo_dir}"
docker run --rm --network none \
  --entrypoint Rscript \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${input_dir}:/generated" \
  "${image_name}" \
  /tests/generate_fixture.R /generated/point_cloud.laz
docker run --rm --network none \
  --volume "${repo_dir}/tests/fixtures:/fixtures:ro" \
  --volume "${input_dir}:/in:ro" \
  --volume "${output_dir}:/out" \
  "${image_name}" \
  --point-cloud /in/point_cloud.laz \
  --aoi /fixtures/aoi.geojson \
  --output-dir /out

python - "${output_dir}/forest_structure_tiles.csv" <<'PY'
import csv
import pathlib
import sys

csv_path = pathlib.Path(sys.argv[1])
if not csv_path.is_file():
    raise SystemExit(f"missing tile CSV: {csv_path}")

with csv_path.open(newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))

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
missing = required.difference(rows[0].keys() if rows else ())
if missing:
    raise SystemExit(f"tile CSV missing columns: {sorted(missing)}")

if len(rows) != 4:
    raise SystemExit(f"expected 4 complete Analysis Tiles, found {len(rows)}")

if [row["tile_id"] for row in rows] != ["1", "2", "3", "4"]:
    raise SystemExit("tile IDs are not deterministic")
PY

