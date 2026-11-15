#!/usr/bin/env bash
# Tests for clone-extensions.sh. Run directly: tests/clone.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=SCRIPTDIR/../../quarto-wizard/tests/helpers.sh
source "${HERE}/../../quarto-wizard/tests/helpers.sh"

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
# manifest entry as id|clone_status, then each ::error:: line the script logged.
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
	sed -n 's/^::error::/ /p' "${run}/log" | tr -d '\n'
}

check 'a valid entry clones' '0 o/r|pass' \
	"$(run_clone '[{"id":"o/r","type":"document"}]')"
check 'an entry with the id "error" fails on its own' '0 error|fail o/r|pass' \
	"$(run_clone '[{"id":"error","type":"document"},{"id":"o/r","type":"document"}]')"
check 'an entry with an empty id stops the batch' '1 Missing required entry fields at index 0 in extensions-batch.json.' \
	"$(run_clone '[{"id":"","type":"document","project_path":"docs"}]')"
check 'a value that starts with a hyphen is recorded, not read as an option' '0 o/r|fail' \
	"$(run_clone '[{"id":"o/r","type":"-n"}]')"

finish
