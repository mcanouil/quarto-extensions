#!/usr/bin/env bash
set -euo pipefail

# Merge test results, generate summary, and publish to quarto-tests branch.
# Inputs (env): SKIPPED, GITHUB_STEP_SUMMARY, GITHUB_REPOSITORY

# --- Merge results ---

skipped_json="${SKIPPED:-[]}"
if ! echo "${skipped_json}" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
  echo "::warning::Invalid skipped payload from build-matrix. Falling back to empty list."
  skipped_json='[]'
fi

today=$(date -u +%Y-%m-%d)

existing_file="test-results.json"
if [[ ! -f "${existing_file}" ]]; then
  echo '{}' >"${existing_file}"
fi
if ! jq -e 'type == "object"' "${existing_file}" >/dev/null 2>&1; then
  echo "::warning::Invalid existing test-results.json payload. Reinitialising to empty object."
  echo '{}' >"${existing_file}"
fi

shopt -s nullglob
result_files=(artefacts/results-batch-*/results.json)
if ((${#result_files[@]} > 0)); then
  raw_current_run=$(jq -sc 'add // []' "${result_files[@]}")
else
  raw_current_run='[]'
fi

current_run_file=$(mktemp)
trap 'rm -f "${current_run_file}"' EXIT

echo "${raw_current_run}" | jq -c '
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
' >"${current_run_file}"
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

jq -c --arg d "${today}" --slurpfile cur "${current_run_file}" '
  reduce $cur[0][] as $e (.;
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
' "${existing_file}" > test-results.tmp && mv test-results.tmp test-results.json

skipped_count=$(echo "${skipped_json}" | jq 'length')

read -r run_total run_pass run_fail run_skip < <(
  jq -r '
    . as $all
    | ($all | [.[].id] | unique | length) as $run_total
    | ($all | sort_by(.id) | group_by(.id)) as $groups
    | ([$groups[] | select(all(.status == "pass"))] | length) as $run_pass
    | ([$groups[] | select(any(.status == "fail"))] | length) as $run_fail
    | ([$groups[] | select(all(.status == "skip"))] | length) as $run_skip
    | [$run_total, $run_pass, $run_fail, $run_skip] | @tsv
  ' "${current_run_file}"
)

if [[ "${run_total}" -eq 0 ]]; then
  echo "::warning::No test results found. All test jobs may have failed before uploading artefacts."
fi

# --- Generate summary ---

release_version=$(jq -r '[.[] | select(.quarto_channel == "release") | .quarto_version] | first // "n/a"' "${current_run_file}")
prerelease_version=$(jq -r '[.[] | select(.quarto_channel == "prerelease") | .quarto_version] | first // "n/a"' "${current_run_file}")
repo_url="https://github.com/${GITHUB_REPOSITORY}/tree/quarto-tests"
results_table=$(jq -r --arg repo_url "${repo_url}" '
  sort_by(.id) | group_by(.id) | .[] |
  {
    id: .[0].id,
    release_status: ([.[] | select(.quarto_channel == "release") | .status] | first // "n/a"),
    release_version: ([.[] | select(.quarto_channel == "release") | .quarto_version] | first // ""),
    prerelease_status: ([.[] | select(.quarto_channel == "prerelease") | .status] | first // "n/a"),
    prerelease_version: ([.[] | select(.quarto_channel == "prerelease") | .quarto_version] | first // "")
  } |
  "| \(.id) | \(if .release_status == "pass" then "[✅](\($repo_url)/logs/\(.id)/release/\(.release_version))" elif .release_status == "fail" then "[❌](\($repo_url)/logs/\(.id)/release/\(.release_version))" elif .release_status == "skip" then "⏭️" else "—" end) | \(if .prerelease_status == "pass" then "[✅](\($repo_url)/logs/\(.id)/prerelease/\(.prerelease_version))" elif .prerelease_status == "fail" then "[❌](\($repo_url)/logs/\(.id)/prerelease/\(.prerelease_version))" elif .prerelease_status == "skip" then "⏭️" else "—" end) |"
' "${current_run_file}")
skipped_list=$(echo "${skipped_json}" | jq -r '.[] | "- \(.)"')

{
  echo "## Test Extensions Summary"
  echo ""
  echo "- **Extensions tested:** ${run_total}"
  echo "- **Pass:** ${run_pass}"
  echo "- **Fail:** ${run_fail}"
  echo "- **Skipped (repository not publicly accessible):** ${run_skip}"
  echo "- **Skipped (no renderable content found):** ${skipped_count}"
  echo ""

  if [[ -n "${results_table}" ]]; then
    echo "### Results"
    echo ""
    echo "<details><summary>Show results</summary>"
    echo ""
    echo "| Extension | Release (${release_version}) | Pre-release (${prerelease_version}) |"
    echo "|-----------|:---:|:---:|"
    echo "${results_table}"
    echo ""
    echo "</details>"
    echo ""
  fi

  if [[ "${skipped_count}" -gt 0 ]]; then
    echo "### Skipped Extensions (${skipped_count})"
    echo ""
    echo "<details><summary>Show skipped extensions</summary>"
    echo ""
    echo "${skipped_list}"
    echo ""
    echo "</details>"
    echo ""
  fi
} >>"${GITHUB_STEP_SUMMARY}"

# --- Stage files ---

while IFS= read -r log_entry; do
  log_channel=$(echo "${log_entry}" | jq -r '.channel')
  log_version=$(echo "${log_entry}" | jq -r '.version')
  if [[ ! "${log_channel}" =~ ^(release|prerelease)$ ]]; then
    echo "::warning::Skipping invalid log channel '${log_channel}'."
    continue
  fi
  if [[ ! "${log_version}" =~ ^[0-9A-Za-z._-]+$ ]]; then
    echo "::warning::Skipping invalid log version '${log_version}'."
    continue
  fi
  git ls-files "logs/*/*/${log_channel}/${log_version}/*" \
    | xargs -r git rm -f -- >/dev/null 2>&1 || true
done < <(jq -c '[.[] | {channel: .quarto_channel, version: .quarto_version}] | unique | .[]' "${current_run_file}")

if [[ -d downloaded-logs ]]; then
  cp -a downloaded-logs/. logs/
fi

if [[ -d logs ]]; then
  git add logs/
fi
git add test-results.json

# --- Commit and push ---

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "ci: update test results (${today})"
  git push origin quarto-tests
fi
