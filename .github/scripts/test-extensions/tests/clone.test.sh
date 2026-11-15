#!/usr/bin/env bash
# Tests for clone-extensions.sh. Run directly: tests/clone.test.sh
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

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# docker answers the version probe and lets every clone succeed, and timeout
# drops its own options, so the script runs with no container and no network.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*"quarto --version"*) echo "1.11.9" ;;
esac
exit 0
STUB
cat >"${WORK}/bin/timeout" <<'STUB'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do shift; done
shift
exec "$@"
STUB
chmod +x "${WORK}/bin/docker" "${WORK}/bin/timeout"

# Clone the given extensions-batch.json, and print the exit status, then each
# manifest entry as id|clone_status.
run_clone() {
	local run="${WORK}/run-$((passed + failed))" status=0
	mkdir -p "${run}"
	printf '%s' "$1" >"${run}/extensions-batch.json"
	(
		cd "${run}"
		PATH="${WORK}/bin:${PATH}" QUARTO_CHANNEL=release GITHUB_WORKSPACE="${run}" \
			bash "${HERE}/../clone-extensions.sh" >"${run}/log" 2>&1
	) || status=$?
	printf '%s' "${status}"
	if [[ -f "${run}/clone-manifest.json" ]]; then
		jq -r '.[] | " \(.id)|\(.clone_status)"' "${run}/clone-manifest.json" | tr -d '\n'
	fi
}

check 'a valid entry clones' '0 o/r|pass' \
	"$(run_clone '[{"id":"o/r","type":"document"}]')"
check 'an entry with the id "error" fails on its own' '0 error|fail o/r|pass' \
	"$(run_clone '[{"id":"error","type":"document"},{"id":"o/r","type":"document"}]')"
check 'an entry with an empty id stops the batch' '1' \
	"$(run_clone '[{"id":"","type":"document","project_path":"docs"}]')"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
