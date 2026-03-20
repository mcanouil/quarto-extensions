#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-config.sh
source "${SCRIPT_DIR}/state-config.sh"
state_dir="${STATE_DIR}"
today_file="${state_dir}/today.txt"

if [[ ! -f "${today_file}" ]]; then
  echo "::error::Missing required state file '${today_file}'."
  exit 1
fi
today=$(cat "${today_file}")
if [[ ! "${today}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "::error::Invalid date value '${today}'."
  exit 1
fi

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "ci: update test results (${today})"
  git push origin quarto-tests
fi
