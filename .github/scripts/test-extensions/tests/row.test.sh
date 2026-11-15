#!/usr/bin/env bash
# Tests for row.jq. Run directly: tests/row.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

passed=0
failed=0

check() {
	local description="$1" expected="$2" actual="$3"
	if [[ "${expected}" == "${actual}" ]]; then
		passed=$((passed + 1))
		printf 'ok   %s\n' "${description}"
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n     expected %s, got %s\n' "${description}" "${expected}" "${actual}"
	fi
}

# Encode a JSON array with row, read it back the way the scripts do, and print
# the fields joined by a pipe.
round_trip() {
	local a b c d
	IFS=$'\x1f' read -r a b c d < <(jq -r -L "${HERE}/.." 'include "row"; row' <<<"$1")
	printf '%s|%s|%s|%s' "${a}" "${b}" "${c}" "${d}"
}

check 'empty fields in the middle keep their place' 'a|||d' "$(round_trip '["a", "", "", "d"]')"
check 'a null field reads as empty' 'a||c|d' "$(round_trip '["a", null, "c", "d"]')"
check 'a backslash is kept as it is' 'a\b|c|d|e' "$(round_trip '["a\\b", "c", "d", "e"]')"
check 'a newline becomes a space' 'a b|c|d|e' "$(round_trip '["a\nb", "c", "d", "e"]')"
check 'a separator inside a value becomes a space' 'a b|c|d|e' "$(round_trip '["a\u001fb", "c", "d", "e"]')"
check 'a number is written as text' '1|c|d|e' "$(round_trip '[1, "c", "d", "e"]')"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
