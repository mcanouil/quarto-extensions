#!/usr/bin/env bash
# Shared helpers for check-extensions scripts. Source this file; do not
# execute it directly.
# Requires env: CSV_FILE, GITHUB_OUTPUT. Optional: DIFF (base64-encoded
# added CSV lines).

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-extensions/retry.sh
source "${LIB_DIR}/../test-extensions/retry.sh"

errors_json="[]"
notes_json="[]"

# Print the added CSV entries from the base64-encoded DIFF, one per line.
read_diff_entries() {
	echo "${DIFF:-}" | base64 --decode | sed '/^$/d'
}

# owner/repo part of a CSV entry (owner/repo[/subdir]).
entry_repo() {
	echo "$1" | cut -d'/' -f1-2
}

# subdir part of a CSV entry, without any trailing slash; empty when absent.
entry_subdir() {
	local subdir
	subdir=$(echo "$1" | cut -d'/' -f3-)
	echo "${subdir%/}"
}

# Print the repository tree paths (one per line); empty output on failure.
fetch_repo_tree() {
	local repo="$1"
	retry 3 2 gh api "repos/${repo}/git/trees/HEAD?recursive=1" --jq '.tree[]? | .path' 2>/dev/null || true
}

# Print the last CSV line number containing the given string.
csv_line_number() {
	local needle="$1"
	grep -n -F -- "${needle}" "${CSV_FILE}" | cut -d: -f1 | tail -n 1
}

append_line_message() {
	local -n target="$1"
	target=$(jq -c \
		--arg line "$2" \
		--arg message "$3" \
		'. += [{"line": $line, "message": $message}]' <<<"${target}")
}

add_error_at() {
	append_line_message errors_json "$1" "$2"
}

add_error() {
	add_error_at "$(csv_line_number "$1")" "$2"
}

add_note_at() {
	append_line_message notes_json "$1" "$2"
}

add_note() {
	add_note_at "$(csv_line_number "$1")" "$2"
}

# Write errors/notes step outputs.
write_check_outputs() {
	{
		echo "errors=${errors_json}"
		echo "notes=${notes_json}"
	} >>"${GITHUB_OUTPUT}"
}

# Exit non-zero when any error was recorded (blocking check semantics).
fail_if_errors() {
	if [[ "${errors_json}" != "[]" ]]; then
		exit 1
	fi
}
