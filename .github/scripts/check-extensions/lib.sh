#!/usr/bin/env bash
# Shared helpers for check-extensions scripts. Source this file; do not
# execute it directly.
# Requires env: CSV_FILE, GITHUB_OUTPUT. Optional: DIFF (base64-encoded
# added CSV lines).

errors_json="[]"
notes_json="[]"

# Print the added CSV entries from the base64-encoded DIFF, one per line.
read_diff_entries() {
	echo "${DIFF:-}" | base64 --decode | sed '/^$/d'
}

# Print the last CSV line number containing the given string.
csv_line_number() {
	local needle="$1"
	grep -n -F -- "${needle}" "${CSV_FILE}" | cut -d: -f1 | tail -n 1
}

add_error_at() {
	local line="$1" message="$2"
	errors_json=$(echo "${errors_json}" | jq -c \
		--arg line "${line}" \
		--arg message "${message}" \
		'. += [{"line": $line, "message": $message}]')
}

add_error() {
	add_error_at "$(csv_line_number "$1")" "$2"
}

add_note_at() {
	local line="$1" message="$2"
	notes_json=$(echo "${notes_json}" | jq -c \
		--arg line "${line}" \
		--arg message "${message}" \
		'. += [{"line": $line, "message": $message}]')
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
