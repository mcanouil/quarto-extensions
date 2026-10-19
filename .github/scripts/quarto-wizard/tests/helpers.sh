#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the quarto-wizard script tests. Source it from a test.

passed=0
failed=0

# Record one check.
# Arguments:
#   $1 - Description
#   $2 - Expected value
#   $3 - Actual value
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

# Print the summary, and fail when a check failed.
finish() {
	printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
	[[ "${failed}" -eq 0 ]]
}

# Install a stub gh in $1/bin. It writes its arguments to $1/query and answers
# with $1/response.json, so a test runs without network access or a token.
# Put $1/bin first on PATH and export STUB_DIR=$1 to use it.
# Arguments:
#   $1 - Work directory
stub_gh() {
	mkdir -p "$1/bin"
	cat >"$1/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${STUB_DIR}/query"
cat "${STUB_DIR}/response.json"
STUB
	chmod +x "$1/bin/gh"
}
