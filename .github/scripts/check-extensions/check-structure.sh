#!/usr/bin/env bash
set -euo pipefail

# Flag added repositories without a valid Quarto extension structure.
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT, GITHUB_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS=, read -r entry; do
	repo=$(entry_repo "${entry}")
	subdir=$(entry_subdir "${entry}")

	tree=$(fetch_repo_tree "${repo}")

	if [[ -z "${tree}" ]]; then
		add_error "${entry}" "Could not retrieve repository file tree to verify the extension structure."
		continue
	fi

	ext_prefix="${subdir:+${subdir}/}"

	has_extension=$(echo "${tree}" | grep -E "^${ext_prefix}_extensions/[^/]+/_extension\.ya?ml$" | head -n 1 || true)
	if [[ -z "${has_extension}" ]]; then
		add_error "${entry}" "Repository is missing a valid Quarto extension structure (\`_extensions/<name>/_extension.yml\`)."
	fi
done < <(read_diff_entries)

write_check_outputs
fail_if_errors
