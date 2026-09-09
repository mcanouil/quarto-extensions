#!/usr/bin/env bash
# Tests for the framework verdict reader in render-extensions.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "${FIXTURES}"' EXIT

# Only the reader is under test, so it is sourced out of the script rather
# than running the whole sweep.
eval "$(sed -n '/^framework_verdict()/,/^}/p' "${HERE}/../render-extensions.sh")"

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

write_fixture() {
	printf '%s' "$2" >"${FIXTURES}/$1.json"
	printf '%s' "${FIXTURES}/$1.json"
}

passing=$(write_fixture passing '{"status":"pass","summary":{"total":3,"pass":3,"fail":0,"skip":0},"layers":{"conformance":{"total":1,"pass":1,"fail":0,"skip":0},"render":{"total":2,"pass":2,"fail":0,"skip":0}}}')
failing=$(write_fixture failing '{"status":"fail","summary":{"total":3,"pass":1,"fail":2,"skip":0},"layers":{"render":{"total":3,"pass":1,"fail":2,"skip":0}}}')
allskip=$(write_fixture allskip '{"status":"skip","summary":{"total":2,"pass":0,"fail":0,"skip":2}}')
# An empty Lua table encodes as an object, not an array, so summary can arrive
# as {} and every field must default rather than read as null.
empty=$(write_fixture empty '{"status":"skip","summary":{}}')

check 'a passing run reports its counts' 'pass	3	3	0	0	2' "$(framework_verdict "${passing}")"
check 'a failing run reports its counts' 'fail	3	1	2	0	3' "$(framework_verdict "${failing}")"
check 'an all-skip run is reported as skip' 'skip	2	0	0	2	0' "$(framework_verdict "${allskip}")"
check 'an empty summary defaults to zeroes' 'skip	0	0	0	0	0' "$(framework_verdict "${empty}")"
check 'a missing file reports none' 'none	0	0	0	0	0' "$(framework_verdict "${FIXTURES}/absent.json")"
check 'unparseable JSON reports none' 'none	0	0	0	0	0' "$(
	write_fixture broken 'not json' >/dev/null
	framework_verdict "${FIXTURES}/broken.json"
)"

# An extension contributing only a project type is the case that matters here.
# generate.lua names a contributed project type as a gap rather than
# half-generating it, so conformance passes, smoke only skips, and the run
# reports pass having rendered nothing at all.
project_only=$(write_fixture project_only '{"status":"pass",
  "summary":{"total":4,"pass":3,"fail":0,"skip":1},
  "layers":{"conformance":{"total":3,"pass":3,"fail":0,"skip":0},
            "smoke":{"total":1,"pass":0,"fail":0,"skip":1}}}')
check 'a run that rendered nothing reports zero rendered' 'pass	4	3	0	1	0' \
	"$(framework_verdict "${project_only}")"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
