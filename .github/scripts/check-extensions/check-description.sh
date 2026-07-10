#!/usr/bin/env bash
set -euo pipefail

# Flag added repositories without a description.
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT, GITHUB_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS=, read -r entry; do
	repo=$(entry_repo "${entry}")
	repo_description=$(gh repo view --json description "${repo}" --jq ".description")
	if [[ -z "${repo_description}" ]]; then
		add_error "${entry}" "Repository is missing description."
	fi
done < <(read_diff_entries)

write_check_outputs
fail_if_errors
