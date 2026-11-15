#!/usr/bin/env bash
# Tests for preflight-render.sh. Run directly: tests/preflight-render.test.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=SCRIPTDIR/../../quarto-wizard/tests/helpers.sh
source "${SCRIPTS}/quarto-wizard/tests/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The script finds its helpers next to itself, so the real scripts are copied
# into a sandbox. The image, clone and render steps are stubs: the render stub
# writes the results.json that the test passes in STUB_RESULTS.
mkdir -p "${WORK}/scripts/check-extensions" "${WORK}/scripts/test-extensions" "${WORK}/run"
cp "${SCRIPTS}/check-extensions/preflight-render.sh" "${SCRIPTS}/check-extensions/lib.sh" \
	"${WORK}/scripts/check-extensions/"
cp "${SCRIPTS}/test-extensions/classify-extension.sh" "${SCRIPTS}/test-extensions/retry.sh" \
	"${WORK}/scripts/test-extensions/"
for step in prepare-image clone-extensions; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"${WORK}/scripts/test-extensions/${step}.sh"
done
cat >"${WORK}/scripts/test-extensions/render-extensions.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_RESULTS}" >results.json
STUB

# Every repository tree holds one standalone document.
export STUB_DIR="${WORK}"
printf 'example.qmd\n' >"${WORK}/response.json"
stub_gh "${WORK}"

# Run the pre-flight for one CSV entry against a canned results.json, and print
# the first note it reports.
run_preflight() {
	local results="$1" entry="$2"
	printf '%s\n' "${entry}" >"${WORK}/run/extensions.csv"
	: >"${WORK}/run/output"
	(
		cd "${WORK}/run"
		PATH="${WORK}/bin:${PATH}" \
			DIFF="$(printf '%s\n' "${entry}" | base64)" \
			CSV_FILE="${WORK}/run/extensions.csv" \
			GITHUB_OUTPUT="${WORK}/run/output" \
			IMAGE="stub" \
			STUB_RESULTS="${results}" \
			bash "${WORK}/scripts/check-extensions/preflight-render.sh" >"${WORK}/run/log" 2>&1 || true
	)
	# A script that stops before it writes its outputs is a broken sandbox, not
	# a wrong note: show its log so the failure can be traced.
	if ! grep -q '^notes=' "${WORK}/run/output"; then
		echo "preflight-render.sh wrote no notes; its output follows:" >&2
		cat "${WORK}/run/log" >&2
		return 0
	fi
	sed -n 's/^notes=//p' "${WORK}/run/output" | jq -r '.[0].message | split("\n")[0]'
}

PASS_RESULTS='[{"id":"o/a","status":"pass","stage":"","failure_reason":"","quarto_version":"1.11.9","log":"logs/o/a"}]'
check 'a pass with no stage reports the Quarto version' \
	'Pre-flight render passed with Quarto 1.11.9 (release).' \
	"$(run_preflight "${PASS_RESULTS}" 'o/a')"

FAIL_RESULTS='[{"id":"o/b","status":"fail","stage":"render","failure_reason":"","quarto_version":"1.11.9","log":"logs/o/b"}]'
# shellcheck disable=SC2016 # The backticks are Markdown in the expected note.
check 'a failure with no reason reports the Quarto version and stage' \
	'Pre-flight render failed with Quarto 1.11.9 (release) at stage `render`.' \
	"$(run_preflight "${FAIL_RESULTS}" 'o/b')"

finish
