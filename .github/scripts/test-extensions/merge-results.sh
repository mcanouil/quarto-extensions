#!/usr/bin/env bash
set -euo pipefail

state_dir=".test-extensions-state"
mkdir -p "${state_dir}"

skipped_json="${SKIPPED:-[]}"
if ! echo "${skipped_json}" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
  echo "::warning::Invalid skipped payload from build-matrix. Falling back to empty list."
  skipped_json='[]'
fi
echo "${skipped_json}" | jq -c '.' >"${state_dir}/skipped.json"

today=$(date -u +%Y-%m-%d)
echo "${today}" >"${state_dir}/today.txt"

if [[ -f test-results.json ]]; then
  existing=$(cat test-results.json)
else
  existing='{}'
fi
if ! echo "${existing}" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "::warning::Invalid existing test-results.json payload. Reinitialising to empty object."
  existing='{}'
fi

shopt -s nullglob
result_files=(artefacts/results-batch-*/results.json)
if ((${#result_files[@]} > 0)); then
  raw_current_run=$(jq -sc 'add // []' "${result_files[@]}")
else
  raw_current_run='[]'
fi

current_run=$(echo "${raw_current_run}" | jq -c '
  [ .[] |
    select(
      (.id | type == "string")
      and (.type | type == "string")
      and (.status | type == "string")
      and (.log | type == "string")
      and (.quarto_version | type == "string")
      and (.quarto_channel | type == "string")
    )
  ]
')
invalid_count=$(echo "${raw_current_run}" | jq '[.[] | select(
  (.id | type != "string")
  or (.type | type != "string")
  or (.status | type != "string")
  or (.log | type != "string")
  or (.quarto_version | type != "string")
  or (.quarto_channel | type != "string")
)] | length')
if [[ "${invalid_count}" -gt 0 ]]; then
  echo "::warning::Dropped ${invalid_count} malformed result entries from artefacts."
fi
echo "${current_run}" | jq '.' >"${state_dir}/current-run.json"

existing=$(jq -c --arg d "${today}" --argjson cur "${current_run}" '
  reduce $cur[] as $e (.;
    .[$e.id] = (
      .[$e.id] // {type: $e.type, results: []}
      | .type = $e.type
      | .results = (
          (.results | map(select(.quarto_version != $e.quarto_version or .quarto_channel != $e.quarto_channel)))
          + [{
              quarto_version: $e.quarto_version,
              quarto_channel: $e.quarto_channel,
              status: $e.status,
              log: $e.log,
              date: $d
            }]
        )
    )
  )
' <<<"${existing}")
echo "${existing}" | jq '.' >test-results.json

skipped_count=$(echo "${skipped_json}" | jq 'length')

echo "${current_run}" | jq -c --argjson sc "${skipped_count}" '
  . as $all
  | ($all | [.[].id] | unique | length) as $run_total
  | ($all | [sort_by(.id) | group_by(.id)[] | select(all(.status == "pass"))] | length) as $run_pass
  | ($all | [sort_by(.id) | group_by(.id)[] | select(any(.status == "fail"))] | length) as $run_fail
  | ($all | [sort_by(.id) | group_by(.id)[] | select(all(.status == "skip"))] | length) as $run_skip
  | {run_total: $run_total, run_pass: $run_pass, run_fail: $run_fail, run_skip: $run_skip, skipped_count: $sc}
' >"${state_dir}/summary-stats.json"

run_total=$(jq -r '.run_total' "${state_dir}/summary-stats.json")
if [[ "${run_total}" -eq 0 ]]; then
  echo "::warning::No test results found. All test jobs may have failed before uploading artefacts."
fi
