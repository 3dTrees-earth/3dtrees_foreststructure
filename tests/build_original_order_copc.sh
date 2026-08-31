#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_laz="${1:-}"
output_copc="${2:-}"
report="${3:-${output_copc}.order.json}"
if [[ ! -f "${source_laz}" || -z "${output_copc}" ]]; then
  echo "usage: $0 ORIGINAL.laz OUTPUT.copc.laz [ORDER_REPORT.json]" >&2
  exit 2
fi

source_laz="$(realpath "${source_laz}")"
output_copc="$(realpath -m "${output_copc}")"
report="$(realpath -m "${report}")"
output_parent="$(dirname "${output_copc}")"
mkdir -p "${output_parent}" "$(dirname "${report}")"
work_dir="$(mktemp -d "${output_parent}/.indexed_copc_XXXXXXXX")"
indexed_laz="${work_dir}/indexed_original.laz"
temporary_copc="${work_dir}/indexed.copc.laz"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

forest_image="${FORESTSTRUCTURE_JULIA_IMAGE:-3dtrees-foreststructure:copc-local}"
smart_tile_image="${FORESTSTRUCTURE_SMART_TILE_IMAGE:-3dtrees-smart-tile:34f492a-v2.3.1}"
test_cpus="${FORESTSTRUCTURE_TEST_CPUS:-10}"
container_memory_gib="${FORESTSTRUCTURE_TEST_MEMORY_GIB:-30}"
host_uid="$(id -u)"
host_gid="$(id -g)"

docker run --rm --network none \
  --cpus "${test_cpus}" \
  --memory "${container_memory_gib}g" \
  --memory-swap "${container_memory_gib}g" \
  --user "${host_uid}:${host_gid}" \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${source_laz}:/in/original.laz:ro" \
  --volume "${work_dir}:/work" \
  --entrypoint python3 \
  "${forest_image}" \
  /tests/add_original_point_index.py \
  /in/original.laz /work/indexed_original.laz

docker run --rm --network none \
  --cpus "${test_cpus}" \
  --memory "${container_memory_gib}g" \
  --memory-swap "${container_memory_gib}g" \
  --user "${host_uid}:${host_gid}" \
  --volume "${work_dir}:/work" \
  --entrypoint untwine \
  "${smart_tile_image}" \
  -i /work/indexed_original.laz -o /work/indexed.copc.laz

docker run --rm --network none \
  --cpus "${test_cpus}" \
  --memory "${container_memory_gib}g" \
  --memory-swap "${container_memory_gib}g" \
  --user "${host_uid}:${host_gid}" \
  --volume "${repo_dir}/tests:/tests:ro" \
  --volume "${source_laz}:/in/original.laz:ro" \
  --volume "${temporary_copc}:/in/indexed.copc.laz:ro" \
  --volume "$(dirname "${report}"):/report" \
  --entrypoint python3 \
  "${forest_image}" \
  /tests/validate_indexed_copc_streaming.py \
  /in/original.laz /in/indexed.copc.laz \
  "/report/$(basename "${report}")" \
  >/dev/null

jq -e '
  .status == "valid" and
  .header_equal == true and
  .fingerprint_equal == true and
  .index_validation.unique_complete_range == true and
  .candidate.extra_dimensions[0] == "OriginalPointIndex" and
  (. as $report |
    [$report.dimensions[] as $dimension |
      (($report.candidate.extra_dimensions | index($dimension)) // 99) < 9] |
    all) and
  .source.scales == .candidate.scales and
  .source.offsets == .candidate.offsets
' "${report}" >/dev/null
mv "${temporary_copc}" "${output_copc}"
echo "original-order COPC built: ${output_copc}"
