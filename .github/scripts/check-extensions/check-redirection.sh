#!/usr/bin/env bash
set -euo pipefail

# Flag added repositories that redirect (renamed or transferred).
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS=, read -r entry; do
	repo=$(echo "${entry}" | cut -d'/' -f1-2)
	if curl -I -s "https://github.com/${repo}" | grep -q "HTTP/.* 30[127]"; then
		redirection_target=$(curl -Ls -o /dev/null -w "%{url_effective}" "https://github.com/${repo}")
		redirection_target=${redirection_target#"https://github.com/"}
		add_error "${entry}" "Repository is redirected to \"${redirection_target}\"."
	fi
done < <(read_diff_entries)

write_check_outputs
fail_if_errors
