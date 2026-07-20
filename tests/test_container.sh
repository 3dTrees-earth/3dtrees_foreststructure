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
  /generated/point_cloud_segmented.laz \
  /generated/aoi_with_exclusion.gpkg

help_path="${results_dir}/help.txt"
docker run --rm --network none "${image_name}" --help > "${help_path}"
for expected_help in \
  "Scientific parameters" \
  "Runtime controls" \
  "--threads" \
  "--tile-size" \
  "default: 20" \
  "--grid-search-step" \
  "default: 0.5" \
  "--instance-dimension" \
  "--segment-diagnostics"; do
  grep -q -- "${expected_help}" "${help_path}"
done

run_failure_case() {
  local name="$1"
  local expected_message="$2"
  local point_cloud_path="$3"
  local aoi_path="$4"
  local output_mode="$5"
  shift 5
  local output_dir="${results_dir}/failure_${name}"
  local log_path="${results_dir}/failure_${name}.log"
  mkdir -p "${output_dir}"

  if docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --volume "${repo_dir}/tests/fixtures:/fixtures:ro" \
    --volume "${input_dir}:/in:ro" \
    --volume "${output_dir}:/out:${output_mode}" \
    "${image_name}" \
    --point-cloud "${point_cloud_path}" \
    --aoi "${aoi_path}" \
    --output-dir /out \
    "$@" > "${log_path}" 2>&1; then
    echo "failure case ${name} unexpectedly succeeded" >&2
    return 1
  fi
  grep -q -- "${expected_message}" "${log_path}"
}

run_failure_case missing_point "exactly one existing LAS/LAZ file" \
  /in/missing.laz /fixtures/aoi.geojson rw
run_failure_case point_directory "exactly one existing LAS/LAZ file" \
  /in /fixtures/aoi.geojson rw
run_failure_case point_extension "must have a .las or .laz extension" \
  /fixtures/aoi.geojson /fixtures/aoi.geojson rw
run_failure_case invalid_tile_size "--tile-size must be greater than zero" \
  /in/point_cloud.laz /fixtures/aoi.geojson rw --tile-size 0
run_failure_case invalid_threads "--threads must be zero or greater" \
  /in/point_cloud.laz /fixtures/aoi.geojson rw --threads -1
run_failure_case malformed_aoi "must contain only Polygon or MultiPolygon" \
  /in/point_cloud.laz /fixtures/aoi_invalid.geojson rw
run_failure_case unwritable_output "--output-dir must be writable" \
  /in/point_cloud.laz /fixtures/aoi.geojson ro

run_case() {
  local name="$1"
  local aoi_path="$2"
  local expected_tiles="$3"
  local point_cloud_path="$4"
  local expected_instance_dimension="$5"
  local expect_diagnostics="$6"
  shift 6
  local output_dir="${results_dir}/${name}"
  local log_path="${output_dir}/container.log"
  mkdir -p "${output_dir}"

  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    --volume "${repo_dir}/tests/fixtures:/fixtures:ro" \
    --volume "${input_dir}:/in:ro" \
    --volume "${output_dir}:/out" \
    "${image_name}" \
    --point-cloud "${point_cloud_path}" \
    --aoi "${aoi_path}" \
    --output-dir /out \
    "$@" 2>&1 | tee "${log_path}"

  python - \
    "${output_dir}" \
    "${expected_tiles}" \
    "${expected_instance_dimension}" \
    "${expect_diagnostics}" <<'PY'
import csv
import json
import pathlib
import sys

output_dir = pathlib.Path(sys.argv[1])
expected_tiles = int(sys.argv[2])
expected_instance_dimension = sys.argv[3]
expect_diagnostics = sys.argv[4] == "yes"
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
    "n_seg_total",
    "n_trees",
    "tree_height_max",
    "tree_height_mean",
    "tree_height_gini",
    "tree_crownarea_mean",
    "tree_crownarea_max",
    "tree_crownarea_gini",
    "tree_volume_mean",
    "tree_volume_max",
    "tree_volume_gini",
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

tree_columns = {
    "n_seg_total",
    "n_trees",
    "tree_height_max",
    "tree_height_mean",
    "tree_height_gini",
    "tree_crownarea_mean",
    "tree_crownarea_max",
    "tree_crownarea_gini",
    "tree_volume_mean",
    "tree_volume_max",
    "tree_volume_gini",
}
if expected_instance_dimension == "NA":
    if any(row[column] != "NA" for row in rows for column in tree_columns):
        raise SystemExit("tree fields must be NA when no instance dimension exists")
elif expected_instance_dimension == "PredInstance":
    if sum(int(row["n_trees"]) for row in rows) != 2:
        raise SystemExit("cross-tile PredInstance trees were not counted exactly once")
elif expected_instance_dimension == "TreeAlias":
    if sum(int(row["n_trees"]) for row in rows) != 1:
        raise SystemExit("ordered Instance Dimension fallback was not honored")

diagnostics_path = output_dir / "segment_diagnostics.csv"
if diagnostics_path.exists() != expect_diagnostics:
    raise SystemExit("segment diagnostics opt-in contract was not honored")
if expect_diagnostics:
    with diagnostics_path.open(newline="", encoding="utf-8") as handle:
        diagnostics = list(csv.DictReader(handle))
    if not diagnostics:
        raise SystemExit("segment diagnostics must contain global segment rows")
    if {row["instance_dimension"] for row in diagnostics} != {
        expected_instance_dimension
    }:
        raise SystemExit("segment diagnostics reported the wrong instance dimension")

performance_path = output_dir / "forest_structure_performance.csv"
expect_performance = output_dir.name == "aliased"
if performance_path.exists() != expect_performance:
    raise SystemExit("performance-report opt-in contract was not honored")
if expect_performance:
    with performance_path.open(newline="", encoding="utf-8") as handle:
        performance_rows = list(csv.DictReader(handle))
    if len(performance_rows) != 1:
        raise SystemExit("performance report must contain exactly one summary row")
    required_performance = {
        "point_count", "tile_count", "peak_rss_mib", "grid_seconds",
        "dtm_seconds", "segment_seconds", "tile_seconds", "output_seconds",
        "total_seconds", "threads_requested", "threads_effective",
    }
    if required_performance.difference(performance_rows[0]):
        raise SystemExit("performance report is missing required measurements")

if not geojson_path.is_file():
    raise SystemExit(f"missing tile GeoJSON: {geojson_path}")
with geojson_path.open(encoding="utf-8") as handle:
    geojson = json.load(handle)
features = geojson.get("features", [])
if len(features) != expected_tiles:
    raise SystemExit("tile GeoJSON feature count does not match the tile CSV")
if [str(feature["properties"]["tile_id"]) for feature in features] != expected_ids:
    raise SystemExit("tile GeoJSON IDs do not match the tile CSV")
for row, feature in zip(rows, features):
    properties = feature["properties"]
    for column, csv_value in row.items():
        geojson_value = properties.get(column)
        if csv_value == "NA":
            if geojson_value is not None:
                raise SystemExit(f"GeoJSON {column} does not match CSV NA")
        elif csv_value in {"TRUE", "FALSE"}:
            if geojson_value is not (csv_value == "TRUE"):
                raise SystemExit(f"GeoJSON {column} does not match CSV boolean")
        elif isinstance(geojson_value, (int, float)):
            if abs(float(csv_value) - float(geojson_value)) > 1e-9:
                raise SystemExit(f"GeoJSON {column} does not match CSV number")
        elif str(geojson_value) != csv_value:
            raise SystemExit(f"GeoJSON {column} does not match CSV value")

if png_path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"missing or invalid PNG: {png_path}")
if dtm_path.read_bytes()[:4] not in (b"II*\x00", b"MM\x00*"):
    raise SystemExit(f"missing or invalid DTM GeoTIFF: {dtm_path}")

chms = sorted(chm_dir.glob("tile_*_chm.tif")) if chm_dir.is_dir() else []
if len(chms) != expected_tiles:
    raise SystemExit(f"expected {expected_tiles} CHMs, found {len(chms)}")
expected_chm_names = [f"tile_{int(tile_id):06d}_chm.tif" for tile_id in expected_ids]
if [path.name for path in chms] != expected_chm_names:
    raise SystemExit("CHM names do not deterministically match tile IDs")
PY

  if [[ "${expected_instance_dimension}" == "NA" ]]; then
    grep -q "No configured Instance Dimension found" "${log_path}"
  else
    grep -q "Using Instance Dimension: ${expected_instance_dimension}" "${log_path}"
  fi
}

run_case inclusion_only /fixtures/aoi.geojson 4 /in/point_cloud.laz NA no
run_case geojson_exclusion /fixtures/aoi_with_exclusion.geojson 3 /in/point_cloud.laz NA no
run_case gpkg_exclusion /in/aoi_with_exclusion.gpkg 3 /in/point_cloud.laz NA no
run_case zero_tiles /fixtures/aoi_zero_tiles.geojson 0 /in/point_cloud.laz NA no
run_case segmented /fixtures/aoi.geojson 4 /in/point_cloud_segmented.laz PredInstance no
run_case aliased /fixtures/aoi.geojson 4 /in/point_cloud_segmented.laz TreeAlias yes \
  --instance-dimension MissingAlias \
  --instance-dimension TreeAlias \
  --instance-dimension PredInstance \
  --segment-diagnostics \
  --performance-report

docker run --rm --network none \
  --user "$(id -u):$(id -g)" \
  --entrypoint Rscript \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${results_dir}:/results:ro" \
  "${image_name}" \
  /tests/verify_rasters.R /results
