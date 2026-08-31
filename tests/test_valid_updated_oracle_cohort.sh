#!/usr/bin/env bash
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${1:-${repo_dir}/tests/fixtures/valid_updated_cohort20_new.tsv}"
data_root="${FORESTSTRUCTURE_DATA_ROOT:-/mnt/ssds/kg281/foreststructure}"
package_root="${FORESTSTRUCTURE_PACKAGE_ROOT:-/mnt/gsdata/projects/3dtrees/forest_structure}"
validation_parent="${VALID_UPDATED_VALIDATION_ROOT:-/mnt/ssds/kg281/_foreststructure_valid_updated_validation}"
image_name="${FORESTSTRUCTURE_JULIA_IMAGE:-3dtrees-foreststructure:julia-memory-safe-local}"
test_cpus="${FORESTSTRUCTURE_TEST_CPUS:-10}"
container_memory_gib="${FORESTSTRUCTURE_TEST_MEMORY_GIB:-30}"
analysis_memory_gib="${FORESTSTRUCTURE_TEST_ANALYSIS_MEMORY_GIB:-25}"
catalog_workers="${FORESTSTRUCTURE_CATALOG_WORKERS:-1}"

if [[ ! -f "${manifest}" ]]; then
  echo "cohort manifest not found: ${manifest}" >&2
  exit 2
fi

mkdir -p "${validation_parent}"
if [[ -n "${VALID_UPDATED_COHORT_ROOT:-}" ]]; then
  cohort_root="$(realpath -m "${VALID_UPDATED_COHORT_ROOT}")"
  mkdir -p "${cohort_root}"
else
  cohort_root="$(mktemp -d "${validation_parent}/oracle_cohort20_XXXXXXXX")"
fi
summary="${cohort_root}/summary.tsv"
printf '%s\n' $'dataset_id\tsource_bytes\tindexed_copc_bytes\tcopc_build_seconds\tvalidation_seconds\ttiles\tsegments\tdtm_cells\tchm_cells\tpeak_rss_mib\tcgroup_peak_mib\tstatus' > "${summary}"
printf 'cohort_root=%s\nimage=%s\nmanifest=%s\ncpus=%s\ncontainer_memory_gib=%s\nanalysis_memory_gib=%s\ncatalog_workers=%s\n' \
  "${cohort_root}" "${image_name}" "$(realpath "${manifest}")" \
  "${test_cpus}" "${container_memory_gib}" "${analysis_memory_gib}" \
  "${catalog_workers}" \
  > "${cohort_root}/run.env"

failures=0
while IFS=$'\t' read -r dataset_id; do
  if [[ "${dataset_id}" == "dataset_id" || -z "${dataset_id}" ]]; then
    continue
  fi

  dataset_root="${cohort_root}/${dataset_id}"
  mkdir -p "${dataset_root}"
  oracle_dir="${package_root}/valid_updated/${dataset_id}"
  valid_dir="${package_root}/valid/${dataset_id}"
  originals=("${data_root}/${dataset_id}/segmented/"*.laz)
  aois=("${data_root}/${dataset_id}/aoi/"*.geojson)
  if [[ -d "${valid_dir}" || ! -d "${oracle_dir}" ||
        ! -f "${originals[0]}" || "${#originals[@]}" != "1" ||
        ! -f "${aois[0]}" || "${#aois[@]}" != "1" ]] ||
      ! jq -e '.status == "valid"' "${oracle_dir}/forest_structure.validation.json" >/dev/null; then
    echo "ORACLE_COHORT dataset=${dataset_id} status=ineligible" | tee "${dataset_root}/status.log"
    printf '%s\n' "${dataset_id}"$'\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\tineligible' >> "${summary}"
    failures=$((failures + 1))
    continue
  fi

  source_bytes="$(stat -c '%s' "${originals[0]}")"
  indexed_copc="${dataset_root}/indexed_copc/input.copc.laz"
  copc_started="$(date +%s)"
  echo "ORACLE_COHORT dataset=${dataset_id} phase=copc status=started"
  if ! FORESTSTRUCTURE_JULIA_IMAGE="${image_name}" \
      FORESTSTRUCTURE_TEST_CPUS="${test_cpus}" \
      FORESTSTRUCTURE_TEST_MEMORY_GIB="${container_memory_gib}" \
      bash "${repo_dir}/tests/build_original_order_copc.sh" \
        "${originals[0]}" "${indexed_copc}" \
        "${dataset_root}/indexed_copc/order_validation.json" \
        > "${dataset_root}/copc_build.log" 2>&1; then
    copc_seconds="$(( $(date +%s) - copc_started ))"
    echo "ORACLE_COHORT dataset=${dataset_id} phase=copc status=failed"
    printf '%s\n' "${dataset_id}"$'\t'"${source_bytes}"$'\t0\t'"${copc_seconds}"$'\t0\t0\t0\t0\t0\t0\t0\tcopc_failed' >> "${summary}"
    failures=$((failures + 1))
    continue
  fi
  copc_seconds="$(( $(date +%s) - copc_started ))"
  indexed_copc_bytes="$(stat -c '%s' "${indexed_copc}")"

  validation_started="$(date +%s)"
  echo "ORACLE_COHORT dataset=${dataset_id} phase=analysis status=started"
  if ! VALID_UPDATED_RUN_ROOT="${dataset_root}/reprocessed" \
      FORESTSTRUCTURE_JULIA_IMAGE="${image_name}" \
      FORESTSTRUCTURE_TEST_CPUS="${test_cpus}" \
      FORESTSTRUCTURE_TEST_MEMORY_GIB="${container_memory_gib}" \
      FORESTSTRUCTURE_TEST_ANALYSIS_MEMORY_GIB="${analysis_memory_gib}" \
      FORESTSTRUCTURE_CATALOG_WORKERS="${catalog_workers}" \
      bash "${repo_dir}/tests/test_valid_updated_copc_alignment.sh" \
        "${dataset_id}" "${indexed_copc}" "${aois[0]}" "${oracle_dir}" \
        PredInstance "${originals[0]}" \
        > "${dataset_root}/reprocessing.log" 2>&1; then
    validation_seconds="$(( $(date +%s) - validation_started ))"
    echo "ORACLE_COHORT dataset=${dataset_id} phase=analysis status=failed"
    printf '%s\n' "${dataset_id}"$'\t'"${source_bytes}"$'\t'"${indexed_copc_bytes}"$'\t'"${copc_seconds}"$'\t'"${validation_seconds}"$'\t0\t0\t0\t0\t0\t0\tvalidation_failed' >> "${summary}"
    failures=$((failures + 1))
    continue
  fi
  validation_seconds="$(( $(date +%s) - validation_started ))"

  performance="${dataset_root}/reprocessed/candidate/${dataset_id}_performance.csv"
  tiles="$(jq -r '.results_csv.actual_rows' "${dataset_root}/reprocessed/science_comparison.json")"
  segments="$(jq -r '.segment_diagnostics_csv.actual_rows' "${dataset_root}/reprocessed/science_comparison.json")"
  dtm_cells="$(jq -r '.cells' "${dataset_root}/reprocessed/dtm_comparison.json")"
  chm_cells="$(jq -r '.cells' "${dataset_root}/reprocessed/chm_comparison.json")"
  peak_rss_mib="$(tail -n 1 "${performance}" | awk -F, '{print $9}')"
  cgroup_peak_mib="$(tail -n 1 "${performance}" | awk -F, '{print $10}')"
  printf '%s\n' "${dataset_id}"$'\t'"${source_bytes}"$'\t'"${indexed_copc_bytes}"$'\t'"${copc_seconds}"$'\t'"${validation_seconds}"$'\t'"${tiles}"$'\t'"${segments}"$'\t'"${dtm_cells}"$'\t'"${chm_cells}"$'\t'"${peak_rss_mib}"$'\t'"${cgroup_peak_mib}"$'\tvalid' >> "${summary}"
  echo "ORACLE_COHORT dataset=${dataset_id} status=valid"
done < "${manifest}"

validated_count="$(awk 'NR > 1 && $12 == "valid" {count++} END {print count + 0}' "${summary}")"
expected_count="$(awk 'NR > 1 && NF > 0 {count++} END {print count + 0}' "${manifest}")"
printf 'validated_count=%s\nexpected_count=%s\nfailures=%s\nstatus=%s\n' \
  "${validated_count}" "${expected_count}" "${failures}" \
  "$([[ "${failures}" == "0" && "${validated_count}" == "${expected_count}" ]] && echo valid || echo invalid)" \
  >> "${cohort_root}/run.env"

if [[ "${failures}" != "0" || "${validated_count}" != "${expected_count}" ]]; then
  echo "valid_updated oracle cohort failed: validated=${validated_count}/${expected_count} cohort_root=${cohort_root}" >&2
  exit 1
fi
echo "valid_updated oracle cohort passed: datasets=${validated_count} cohort_root=${cohort_root}"
