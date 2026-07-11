#!/usr/bin/env bash
set -euo pipefail

# Flag duplicated entries in the extensions CSV.
# Inputs (env): CSV_FILE, GITHUB_OUTPUT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS= read -r duplicate; do
	while IFS= read -r line_number; do
		add_error_at "${line_number}" "Repository is duplicated."
	done < <(grep -n "${duplicate}" "${CSV_FILE}" | cut -d: -f1 | tail -n +2)
done < <(sort -f "${CSV_FILE}" | uniq -di)

write_check_outputs
fail_if_errors
