#!/usr/bin/env bash
# Tests for lib/latest-tag.jq. Run directly: tests/latest-tag.test.sh
#
# The cases mirror the tests of resolveLatestTag and normaliseVersion in Quarto
# Wizard (packages/core/tests/github-latest.test.ts), for a stable install.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib"

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

# Latest tag of a repository, as compact JSON.
# Arguments:
#   $1 - Releases as a JSON array of {tagName, url, isPrerelease, isDraft}
#   $2 - Tag names as a JSON array of strings
latest_of() {
	jq -nc -L "${LIB}" --argjson releases "$1" --argjson tags "$2" \
		'include "latest-tag"; {releases: $releases, tags: $tags} | latest_tag'
}

# Normalised stable version of a tag name, or null.
version_of() {
	jq -nc -L "${LIB}" --arg name "$1" 'include "latest-tag"; $name | stable_version'
}

release() {
	local prerelease="${2:-false}" draft="${3:-false}"
	printf '{"tagName":"%s","url":"https://github.com/o/r/releases/tag/%s","isPrerelease":%s,"isDraft":%s}' \
		"$1" "$1" "${prerelease}" "${draft}"
}

check 'picks the highest version, not the latest release marker' \
	'{"tagName":"v1.3.0","url":null}' \
	"$(latest_of "[$(release v1.2.0)]" '["v1.2.0","v1.3.0"]')"

check 'ignores prerelease versions' \
	'{"tagName":"v1.4.0","url":null}' \
	"$(latest_of '[]' '["v2.0.0-beta.1","v1.4.0"]')"

check 'ignores tags that are not versions' \
	'{"tagName":"v1.0.0","url":null}' \
	"$(latest_of '[]' '["latest","nightly","v1.0.0"]')"

check 'ignores tags that only contain a version' \
	'{"tagName":"v1.0.0","url":null}' \
	"$(latest_of '[]' '["build-20240101","schema-v9.0.0","release-3","v1.0.0"]')"

check 'is null when no tag qualifies' \
	'null' \
	"$(latest_of "[$(release v3.0.0-rc.1 true)]" '["nightly","v3.0.0-rc.1"]')"

check 'is null for a repository without tags' \
	'null' \
	"$(latest_of '[]' '[]')"

check 'treats a release flagged as a prerelease as a prerelease' \
	'{"tagName":"v1.5.0","url":"https://github.com/o/r/releases/tag/v1.5.0"}' \
	"$(latest_of "[$(release v2.0.0 true),$(release v1.5.0)]" '["v2.0.0","v1.5.0"]')"

check 'ignores a draft release' \
	'{"tagName":"v1.0.0","url":"https://github.com/o/r/releases/tag/v1.0.0"}' \
	"$(latest_of "[$(release v2.0.0 false true),$(release v1.0.0)]" '["v1.0.0"]')"

check 'keeps the release URL when a tag has the same version' \
	'{"tagName":"1.2.0","url":"https://github.com/o/r/releases/tag/1.2.0"}' \
	"$(latest_of "[$(release 1.2.0)]" '["1.2.0"]')"

check 'compares versions as numbers, not as text' \
	'{"tagName":"v1.10.0","url":null}' \
	"$(latest_of '[]' '["v1.9.0","v1.10.0","v1.2.0"]')"

check 'strips a leading v' '[1,2,3]' "$(version_of v1.2.3)"
check 'fills missing parts with zero' '[1,2,0]' "$(version_of 1.2)"
check 'accepts a major version alone' '[3,0,0]' "$(version_of 3)"
check 'drops build metadata' '[1,2,3]' "$(version_of v1.2.3+build.5)"
check 'rejects a prerelease' 'null' "$(version_of 1.2-rc.1)"
check 'rejects a name that is not a version' 'null' "$(version_of nightly)"
check 'rejects an empty name' 'null' "$(version_of '')"
check 'rejects a version inside a longer name' 'null' "$(version_of quarto-1.4)"
check 'rejects two leading v' 'null' "$(version_of vv1.0.0)"
check 'rejects four parts' 'null' "$(version_of 1.2.3.4)"
check 'rejects a dot after the v' 'null' "$(version_of v.1.0.0)"
check 'rejects a leading zero' 'null' "$(version_of 01.2.3)"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
