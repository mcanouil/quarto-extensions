#!/usr/bin/env bash
set -euo pipefail

state_dir=".test-extensions-state"
stats_file="${state_dir}/summary-stats.json"
current_run_file="${state_dir}/current-run.json"
skipped_file="${state_dir}/skipped.json"

for required in "${stats_file}" "${current_run_file}" "${skipped_file}"; do
  if [[ ! -f "${required}" ]]; then
    echo "::error::Missing required state file '${required}'."
    exit 1
  fi
done

run_total=$(jq -r '.run_total' "${stats_file}")
run_pass=$(jq -r '.run_pass' "${stats_file}")
run_fail=$(jq -r '.run_fail' "${stats_file}")
run_skip=$(jq -r '.run_skip' "${stats_file}")
skipped_count=$(jq -r '.skipped_count' "${stats_file}")

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
skipped_list=$(jq -r '.[] | "- \(.)"' "${skipped_file}")

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
