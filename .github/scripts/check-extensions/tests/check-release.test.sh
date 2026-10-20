#!/usr/bin/env bash
# Tests for check-release.sh. Run directly: tests/check-release.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../check-release.sh"

# shellcheck source=SCRIPTDIR/../../quarto-wizard/tests/helpers.sh
source "${HERE}/../../quarto-wizard/tests/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Install a stub gh in ${WORK}/bin that answers per endpoint, and applies --jq
# to the canned response as gh does.
# Responses: view.json (gh repo view), releases.json, tags.json.
install_gh() {
	mkdir -p "${WORK}/bin"
	cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
file=""
case "$*" in
"repo view"*) file="view.json" ;;
*"/releases?"*) file="releases.json" ;;
*"/tags"*) file="tags.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
if [[ -e "${STUB_DIR}/fail-${file}" ]]; then
	echo "gh: simulated failure" >&2
	exit 1
fi
filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	if [[ "${args[i]}" == "--jq" ]]; then
		filter="${args[i + 1]}"
	fi
done
if [[ -n "${filter}" ]]; then
	jq -r "${filter}" "${STUB_DIR}/${file}"
else
	cat "${STUB_DIR}/${file}"
fi
STUB
	chmod +x "${WORK}/bin/gh"
}

# Run check-release.sh for one entry and print "<exit> <errors> <notes>".
# Arguments:
#   $1 - Latest release as gh repo view reports it (empty for none)
#   $2 - Releases as the API returns them
#   $3 - Tags as the API returns them
#   $4 - Optional stub file whose gh call fails, such as tags.json
run_check() {
	printf '%s' "$1" >"${WORK}/view.json"
	printf '%s' "$2" >"${WORK}/releases.json"
	printf '%s' "$3" >"${WORK}/tags.json"
	: >"${WORK}/output"
	rm -f "${WORK}"/fail-*
	if [[ -n "${4:-}" ]]; then
		: >"${WORK}/fail-$4"
	fi
	printf 'owner/repo\n' >"${WORK}/extensions.csv"
	local status=0
	STUB_DIR="${WORK}" PATH="${WORK}/bin:${PATH}" \
		CSV_FILE="${WORK}/extensions.csv" GITHUB_OUTPUT="${WORK}/output" \
		DIFF="$(printf 'owner/repo\n' | base64)" \
		bash "${SCRIPT}" >/dev/null 2>&1 || status=$?
	printf '%s %s %s' "${status}" \
		"$(sed -n 's/^errors=//p' "${WORK}/output")" \
		"$(sed -n 's/^notes=//p' "${WORK}/output")"
}

install_gh

NOTE='No release or tag is a stable version, such as 1.2.3 or v1.2.3. Quarto Wizard will not offer updates for this extension until one is.'

check "a stable release raises nothing" \
	'0 [] []' \
	"$(run_check '{"tagName":"v1.0.0"}' \
		'[{"tag_name":"v1.0.0","html_url":"https://github.com/owner/repo/releases/tag/v1.0.0","prerelease":false,"draft":false}]' \
		'[{"name":"v1.0.0"}]')"

check "a stable tag without a release raises nothing" \
	'0 [] []' \
	"$(run_check '' '[]' '[{"name":"1.2.3"}]')"

check "only the tag latest adds a note" \
	"0 [] [{\"line\":\"1\",\"message\":\"${NOTE}\"}]" \
	"$(run_check '' '[]' '[{"name":"latest"}]')"

check "only a prerelease adds a note" \
	"0 [] [{\"line\":\"1\",\"message\":\"${NOTE}\"}]" \
	"$(run_check '{"tagName":"v2.0.0-rc1"}' \
		'[{"tag_name":"v2.0.0-rc1","html_url":"u","prerelease":true,"draft":false}]' \
		'[{"name":"v2.0.0-rc1"}]')"

check "a failing tags call adds no note and no error" \
	'0 [] []' \
	"$(run_check '{"tagName":"v2.0.0-rc1"}' '[]' '[]' tags.json)"

check "a failing releases call adds no note and no error" \
	'0 [] []' \
	"$(run_check '' '[]' '[{"name":"latest"}]' releases.json)"

check "no release and no tag keeps the error" \
	'1 [{"line":"1","message":"Repository is missing release/tag."}] []' \
	"$(run_check '' '[]' '[]')"

finish
