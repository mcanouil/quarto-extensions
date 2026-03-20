#!/usr/bin/env bash
set -euo pipefail

state_dir=".test-extensions-state"
current_run_file="${state_dir}/current-run.json"

if [[ ! -f "${current_run_file}" ]]; then
  echo "::error::Missing required state file '${current_run_file}'."
  exit 1
fi

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
  while IFS= read -r tracked_file; do
    if [[ -n "${tracked_file}" ]]; then
      git rm -f -- "${tracked_file}" >/dev/null
    fi
  done < <(git ls-files "logs/*/*/${log_channel}/${log_version}/*")
done < <(jq -c '[.[] | {channel: .quarto_channel, version: .quarto_version}] | unique | .[]' "${current_run_file}")

if [[ -d logs ]]; then
  git add logs/
fi
git add test-results.json
