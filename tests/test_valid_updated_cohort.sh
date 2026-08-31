#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${1:-${repo_dir}/tests/fixtures/valid_updated_cohort15.tsv}"
data_root="${FORESTSTRUCTURE_DATA_ROOT:-/mnt/ssds/kg281/foreststructure}"
package_root="${FORESTSTRUCTURE_PACKAGE_ROOT:-/mnt/gsdata/projects/3dtrees/forest_structure}"
validation_parent="${VALID_UPDATED_VALIDATION_ROOT:-/mnt/ssds/kg281/_foreststructure_valid_updated_validation}"
image_name="${FORESTSTRUCTURE_JULIA_IMAGE:-3dtrees-foreststructure:julia-memory-safe-local}"
if [[ ! -f "${manifest}" ]]; then
  echo "cohort manifest not found: ${manifest}" >&2
  exit 2
fi

mkdir -p "${validation_parent}"
cohort_root="$(mktemp -d "${validation_parent}/cohort15_XXXXXXXX")"
summary="${cohort_root}/summary.tsv"
printf '%s\n' $'dataset_id\tbaseline\tlegacy_result_differences\tlegacy_segment_differences\tlegacy_geojson_equal\ttiles\tsegments\tdtm_cells\tchm_cells\tcopc_build_seconds\tindexed_copc_bytes\ttotal_seconds\tpeak_rss_mib\tcgroup_peak_mib\tstatus' > "${summary}"
printf 'cohort_root=%s\nimage=%s\nmanifest=%s\n' \
  "${cohort_root}" "${image_name}" "$(realpath "${manifest}")" \
  > "${cohort_root}/run.env"

while IFS=$'\t' read -r dataset_id baseline; do
  if [[ "${dataset_id}" == "dataset_id" || -z "${dataset_id}" ]]; then
    continue
  fi
  if [[ "${baseline}" != "valid" && "${baseline}" != "pending_xy_rescale" ]]; then
    echo "invalid baseline ${baseline} for dataset ${dataset_id}" >&2
    exit 2
  fi

  dataset_root="${cohort_root}/${dataset_id}"
  mkdir -p "${dataset_root}"
  oracle_dir="${package_root}/valid_updated/${dataset_id}"
  legacy_dir="${package_root}/${baseline}/${dataset_id}"
  originals=("${data_root}/${dataset_id}/segmented/"*.laz)
  aois=("${data_root}/${dataset_id}/aoi/"*.geojson)
  if [[ ! -f "${originals[0]}" || ! -f "${aois[0]}" ||
        ! -d "${oracle_dir}" ||
        ! -d "${legacy_dir}" ]]; then
    echo "dataset ${dataset_id} is missing a required input or comparison folder" >&2
    exit 2
  fi

  legacy_report="${dataset_root}/legacy_vs_valid_updated.json"
  set +e
  /usr/bin/python3 "${repo_dir}/tests/compare_valid_updated_science.py" \
    "${dataset_id}" PredInstance "${oracle_dir}" "${legacy_dir}" \
    "${legacy_report}" > "${dataset_root}/legacy_comparison.log" 2>&1
  legacy_status=$?
  set -e
  if [[ "${legacy_status}" == "0" ]]; then
    echo "dataset ${dataset_id} does not demonstrate a ${baseline}/valid_updated difference" >&2
    exit 1
  fi

  indexed_copc="${dataset_root}/indexed_copc/input.copc.laz"
  copc_build_started="$(date +%s)"
  bash "${repo_dir}/tests/build_original_order_copc.sh" \
    "${originals[0]}" "${indexed_copc}" \
    "${dataset_root}/indexed_copc/order_validation.json" \
    > "${dataset_root}/copc_build.log" 2>&1
  copc_build_seconds="$(( $(date +%s) - copc_build_started ))"
  indexed_copc_bytes="$(stat -c '%s' "${indexed_copc}")"

  echo "COHORT dataset=${dataset_id} baseline=${baseline} status=started"
  VALID_UPDATED_RUN_ROOT="${dataset_root}/reprocessed" \
  FORESTSTRUCTURE_JULIA_IMAGE="${image_name}" \
  bash "${repo_dir}/tests/test_valid_updated_copc_alignment.sh" \
    "${dataset_id}" "${indexed_copc}" "${aois[0]}" "${oracle_dir}" \
    PredInstance "${originals[0]}" \
    > "${dataset_root}/reprocessing.log" 2>&1

  legacy_result_differences="$(jq -r '.results_csv.differing_values' "${legacy_report}")"
  legacy_segment_differences="$(jq -r '.segment_diagnostics_csv.differing_values' "${legacy_report}")"
  legacy_geojson_equal="$(jq -r '.tiles_geojson.equal' "${legacy_report}")"
  candidate_dir="${dataset_root}/reprocessed/candidate"
  performance="${candidate_dir}/${dataset_id}_performance.csv"
  tiles="$(jq -r '.results_csv.actual_rows' "${dataset_root}/reprocessed/science_comparison.json")"
  segments="$(jq -r '.segment_diagnostics_csv.actual_rows' "${dataset_root}/reprocessed/science_comparison.json")"
  dtm_cells="$(jq -r '.cells' "${dataset_root}/reprocessed/dtm_comparison.json")"
  chm_cells="$(jq -r '.cells' "${dataset_root}/reprocessed/chm_comparison.json")"
  total_seconds="$(tail -n 1 "${performance}" | awk -F, '{print $18}')"
  peak_rss_mib="$(tail -n 1 "${performance}" | awk -F, '{print $9}')"
  cgroup_peak_mib="$(tail -n 1 "${performance}" | awk -F, '{print $10}')"
  printf '%s\n' "${dataset_id}"$'\t'"${baseline}"$'\t'"${legacy_result_differences}"$'\t'"${legacy_segment_differences}"$'\t'"${legacy_geojson_equal}"$'\t'"${tiles}"$'\t'"${segments}"$'\t'"${dtm_cells}"$'\t'"${chm_cells}"$'\t'"${copc_build_seconds}"$'\t'"${indexed_copc_bytes}"$'\t'"${total_seconds}"$'\t'"${peak_rss_mib}"$'\t'"${cgroup_peak_mib}"$'\tvalid' \
    >> "${summary}"
  echo "COHORT dataset=${dataset_id} baseline=${baseline} status=valid"
done < "${manifest}"

validated_count="$(awk 'NR > 1 && $15 == "valid" {count++} END {print count + 0}' "${summary}")"
expected_count="$(awk 'NR > 1 && NF > 0 {count++} END {print count + 0}' "${manifest}")"
if [[ "${validated_count}" != "${expected_count}" ]]; then
  echo "validated ${validated_count} of ${expected_count} cohort datasets" >&2
  exit 1
fi
printf 'validated_count=%s\nstatus=valid\n' "${validated_count}" \
  >> "${cohort_root}/run.env"
echo "valid_updated cohort passed: datasets=${validated_count} cohort_root=${cohort_root}"
