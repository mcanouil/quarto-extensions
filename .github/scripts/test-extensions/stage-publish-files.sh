#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-config.sh
source "${SCRIPT_DIR}/state-config.sh"
state_dir="${STATE_DIR}"
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
  git ls-files "logs/*/*/${log_channel}/${log_version}/*" \
    | xargs -r git rm -f -- >/dev/null 2>&1 || true
done < <(jq -c '[.[] | {channel: .quarto_channel, version: .quarto_version}] | unique | .[]' "${current_run_file}")

if [[ -d logs ]]; then
  git add logs/
fi
git add test-results.json
