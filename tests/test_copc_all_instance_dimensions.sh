#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="${FORESTSTRUCTURE_JULIA_IMAGE:-3dtrees-foreststructure:copc-local}"
smart_tile_image="${FORESTSTRUCTURE_SMART_TILE_IMAGE:-3dtrees-smart-tile:34f492a-v2.3.1}"
test_root="$(mktemp -d)"
cleanup() {
  if [[ "${FORESTSTRUCTURE_KEEP_TEST_ROOT:-0}" == "1" ]]; then
    echo "Preserving test root: ${test_root}"
  else
    rm -rf "${test_root}"
  fi
}
trap cleanup EXIT
echo "COPC all-dimension test root: ${test_root}"
mkdir -p \
  "${test_root}/input" \
  "${test_root}/ordered-output" \
  "${test_root}/ordered-work" \
  "${test_root}/copc-output" \
  "${test_root}/copc-work"

docker run --rm --network none \
  --user "$(id -u):$(id -g)" \
  --entrypoint Rscript \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${test_root}/input:/generated" \
  "${image_name}" \
  /tests/generate_julia_memory_safe_fixture.R \
  /generated/distinct.laz /generated/aoi.geojson distinct-dimensions

FORESTSTRUCTURE_JULIA_IMAGE="${image_name}" \
FORESTSTRUCTURE_SMART_TILE_IMAGE="${smart_tile_image}" \
FORESTSTRUCTURE_TEST_CPUS=2 \
FORESTSTRUCTURE_TEST_MEMORY_GIB=4 \
  bash "${repo_dir}/tests/build_original_order_copc.sh" \
  "${test_root}/input/distinct.laz" \
  "${test_root}/input/distinct.copc.laz" \
  "${test_root}/input/order-validation.json"

run_foreststructure() {
  local point_cloud="$1"
  local output_dir="$2"
  local work_dir="$3"
  local point_cloud_name
  point_cloud_name="$(basename "${point_cloud}")"
  shift 3
  docker run --rm --network none \
    --cpus 2 \
    --memory 4g \
    --memory-swap 4g \
    --user "$(id -u):$(id -g)" \
    --env FORESTSTRUCTURE_THREADS=2 \
    --env FORESTSTRUCTURE_CATALOG_WORKERS=1 \
    --volume "${test_root}/input:/in:ro" \
    --volume "${output_dir}:/out" \
    --volume "${work_dir}:/work" \
    "${image_name}" \
    --point-cloud "/in/${point_cloud_name}" \
    "$@" \
    --aoi-geojson /in/aoi.geojson \
    --dataset-id 150 \
    --output-dir /out \
    --temp-dir /work \
    --memory-budget-gib 3
}

run_foreststructure \
  "${test_root}/input/distinct.laz" \
  "${test_root}/ordered-output" \
  "${test_root}/ordered-work" \
  2>&1 | tee "${test_root}/ordered.log"
run_foreststructure \
  "${test_root}/input/distinct.copc.laz" \
  "${test_root}/copc-output" \
  "${test_root}/copc-work" \
  --original-point-cloud /in/distinct.laz \
  2>&1 | tee "${test_root}/copc.log"

for dimension in PredInstance PredInstance_SAT PredInstance_FM; do
  for artifact in results.csv segment_diagnostics.csv tiles.geojson; do
    cmp \
      "${test_root}/ordered-output/150_${dimension}_${artifact}" \
      "${test_root}/copc-output/150_${dimension}_${artifact}"
  done
done
for raster in dtm.tif chm.tif; do
  cmp \
    "${test_root}/ordered-output/150_${raster}" \
    "${test_root}/copc-output/150_${raster}"
done

if cmp -s \
  "${test_root}/copc-output/150_PredInstance_results.csv" \
  "${test_root}/copc-output/150_PredInstance_SAT_results.csv"; then
  echo "PredInstance and PredInstance_SAT unexpectedly produced identical results" >&2
  exit 1
fi
if cmp -s \
  "${test_root}/copc-output/150_PredInstance_SAT_results.csv" \
  "${test_root}/copc-output/150_PredInstance_FM_results.csv"; then
  echo "PredInstance_SAT and PredInstance_FM unexpectedly produced identical results" >&2
  exit 1
fi

jq -e '
  .requested_is_copc == true and
  .point_order_dimension == "OriginalPointIndex" and
  .processed_instance_dimensions == [
    "PredInstance", "PredInstance_SAT", "PredInstance_FM"
  ]
' "${test_root}/copc-output/150_julia_memory_safe_run.json" >/dev/null

echo "COPC all-instance-dimension differential acceptance passed"
