#!/usr/bin/env bash
# Tests for preflight-render.sh. Run directly: tests/preflight-render.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/../.." && pwd)"

# shellcheck source=SCRIPTDIR/../../quarto-wizard/tests/helpers.sh
source "${SCRIPTS}/quarto-wizard/tests/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The script finds its helpers next to itself, so the real scripts are copied
# into a sandbox. The image, clone and render steps are stubs: the render stub
# writes the results.json that the test gives it.
mkdir -p "${WORK}/scripts/check-extensions" "${WORK}/scripts/test-extensions" "${WORK}/bin" "${WORK}/run"
cp "${SCRIPTS}/check-extensions/preflight-render.sh" "${SCRIPTS}/check-extensions/lib.sh" \
	"${WORK}/scripts/check-extensions/"
cp "${SCRIPTS}/test-extensions/classify-extension.sh" "${SCRIPTS}/test-extensions/retry.sh" \
	"${WORK}/scripts/test-extensions/"
printf '#!/usr/bin/env bash\nexit 0\n' >"${WORK}/scripts/test-extensions/prepare-image.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"${WORK}/scripts/test-extensions/clone-extensions.sh"
cat >"${WORK}/scripts/test-extensions/render-extensions.sh" <<'STUB'
#!/usr/bin/env bash
cp "${STUB_RESULTS}" results.json
STUB
printf '#!/usr/bin/env bash\nprintf "example.qmd\\n"\n' >"${WORK}/bin/gh"
chmod +x "${WORK}/bin/gh"

# Run the pre-flight for the given CSV entries against a canned results.json,
# and print the notes it reports, one message per line.
run_preflight() {
	local results="$1"
	shift
	printf '%s\n' "$@" >"${WORK}/run/extensions.csv"
	printf '%s' "${results}" >"${WORK}/run/results-in.json"
	: >"${WORK}/run/output"
	(
		cd "${WORK}/run"
		PATH="${WORK}/bin:${PATH}" \
			DIFF="$(printf '%s\n' "$@" | base64)" \
			CSV_FILE="${WORK}/run/extensions.csv" \
			GITHUB_OUTPUT="${WORK}/run/output" \
			IMAGE="stub" \
			STUB_RESULTS="${WORK}/run/results-in.json" \
			bash "${WORK}/scripts/check-extensions/preflight-render.sh" >/dev/null 2>&1 || true
	)
	sed -n 's/^notes=//p' "${WORK}/run/output" | jq -r '.[].message' | head -n 1
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
