#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dataset_id="${1:-1338}"
point_cloud="${2:-}"
aoi_geojson="${3:-}"
oracle_dir="${4:-}"
dimension="${5:-PredInstance}"
original_point_cloud="${6:-}"
if [[ ! -f "${point_cloud}" || ! -f "${original_point_cloud}" ||
      ! -f "${aoi_geojson}" || ! -d "${oracle_dir}" ]]; then
  echo "usage: $0 DATASET_ID INPUT.copc.laz AOI.geojson VALID_UPDATED_DIR [DIMENSION] ORIGINAL.laz" \
    >&2
  exit 2
fi
if [[ "${point_cloud,,}" != *.copc.laz ]]; then
  echo "alignment regression requires a COPC input" >&2
  exit 2
fi

point_cloud="$(realpath "${point_cloud}")"
original_point_cloud="$(realpath "${original_point_cloud}")"
aoi_geojson="$(realpath "${aoi_geojson}")"
oracle_dir="$(realpath "${oracle_dir}")"
image_name="${FORESTSTRUCTURE_JULIA_IMAGE:-3dtrees-foreststructure:julia-memory-safe-local}"
source_mount="${FORESTSTRUCTURE_SOURCE_MOUNT:-}"
test_cpus="${FORESTSTRUCTURE_TEST_CPUS:-10}"
container_memory_gib="${FORESTSTRUCTURE_TEST_MEMORY_GIB:-30}"
analysis_memory_gib="${FORESTSTRUCTURE_TEST_ANALYSIS_MEMORY_GIB:-25}"
validation_parent="${VALID_UPDATED_VALIDATION_ROOT:-/mnt/ssds/kg281/_foreststructure_valid_updated_validation}"
mkdir -p "${validation_parent}"
if [[ -n "${VALID_UPDATED_RUN_ROOT:-}" ]]; then
  run_root="$(realpath -m "${VALID_UPDATED_RUN_ROOT}")"
  mkdir -p "${run_root}"
else
  run_root="$(mktemp -d "${validation_parent}/dataset${dataset_id}_XXXXXXXX")"
fi
candidate_dir="${run_root}/candidate"
candidate_work="${run_root}/work"
mkdir -p "${candidate_dir}" "${candidate_work}"

container_name="foreststructure_valid_updated_${dataset_id}_$$_${RANDOM}"
cleanup_container() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
}
source_mount_args=()
if [[ -n "${source_mount}" ]]; then
  source_mount="$(realpath "${source_mount}")"
  source_mount_args=(--volume "${source_mount}:/opt/foreststructure:ro")
fi
trap cleanup_container EXIT
set +e
docker run \
  --name "${container_name}" \
  --network none \
  --cpus "${test_cpus}" \
  --memory "${container_memory_gib}g" \
  --memory-swap "${container_memory_gib}g" \
  --user "$(id -u):$(id -g)" \
  --env "FORESTSTRUCTURE_THREADS=${test_cpus}" \
  --env "FORESTSTRUCTURE_CATALOG_WORKERS=${FORESTSTRUCTURE_CATALOG_WORKERS:-1}" \
  --volume "${point_cloud}:/in/input.copc.laz:ro" \
  --volume "${original_point_cloud}:/in/original.laz:ro" \
  --volume "${aoi_geojson}:/in/aoi.geojson:ro" \
  --volume "${candidate_dir}:/out" \
  --volume "${candidate_work}:/work" \
  "${source_mount_args[@]}" \
  "${image_name}" \
  --point-cloud /in/input.copc.laz \
  --original-point-cloud /in/original.laz \
  --aoi-geojson /in/aoi.geojson \
  --dataset-id "${dataset_id}" \
  --output-dir /out \
  --temp-dir /work \
  --memory-budget-gib "${analysis_memory_gib}" \
  --instance-dimension "${dimension}" \
  2>&1 | tee "${run_root}/candidate.log"
docker_status="${PIPESTATUS[0]}"
set -e
if [[ "${docker_status}" != "0" ]]; then
  echo "candidate failed before valid_updated comparison; run_root=${run_root}" >&2
  exit "${docker_status}"
fi
docker rm "${container_name}" >/dev/null
trap - EXIT

jq -e '
  .requested_is_copc == true and
  .source_is_copc == true and
  .companion_header_identity_validated == true and
  .point_order_dimension == "OriginalPointIndex" and
  .catalog_spatial_streaming == "COPC" and
  (.requested_point_cloud | endswith("input.copc.laz")) and
  (.source_point_cloud | endswith("input.copc.laz")) and
  (.original_point_cloud | endswith("original.laz"))
' "${candidate_dir}/${dataset_id}_julia_memory_safe_run.json" >/dev/null

/usr/bin/python3 "${repo_dir}/tests/compare_valid_updated_science.py" \
  "${dataset_id}" "${dimension}" "${oracle_dir}" "${candidate_dir}" \
  "${run_root}/science_comparison.json"

for raster in dtm chm; do
  docker run --rm --network none \
    --cpus "${test_cpus}" \
    --memory "${container_memory_gib}g" \
    --memory-swap "${container_memory_gib}g" \
    --user "$(id -u):$(id -g)" \
    --entrypoint Rscript \
    --volume "${repo_dir}/tests:/tests:ro" \
    --volume "${oracle_dir}/${dataset_id}_${raster}.tif:/validation/expected.tif:ro" \
    --volume "${candidate_dir}/${dataset_id}_${raster}.tif:/validation/actual.tif:ro" \
    --volume "${run_root}:/report" \
    "${image_name}" /tests/compare_valid_updated_raster.R \
    "${raster}" /validation/expected.tif /validation/actual.tif \
    "/report/${raster}_comparison.json"
done

echo "COPC/valid_updated alignment passed: run_root=${run_root}"
