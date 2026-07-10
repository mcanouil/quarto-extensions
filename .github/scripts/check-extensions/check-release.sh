#!/usr/bin/env bash
set -euo pipefail

# Flag added repositories without a release or tag.
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT, GITHUB_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS=, read -r entry; do
	repo=$(echo "${entry}" | cut -d'/' -f1-2)
	repo_release=$(gh repo view --json latestRelease "${repo}" --jq ".latestRelease")
	if [[ -z "${repo_release}" ]]; then
		add_error "${entry}" "Repository is missing release/tag."
	fi
done < <(read_diff_entries)

write_check_outputs
fail_if_errors
