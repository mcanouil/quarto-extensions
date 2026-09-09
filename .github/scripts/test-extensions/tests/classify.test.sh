#!/usr/bin/env bash
# Tests for classify-extension.sh. Run directly: tests/classify.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../classify-extension.sh"

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

mode_of() {
	printf '%s\n' "$1" | detect_test_mode
}

SUITE_TREE='_extensions/demo/_extension.yml
_extensions/demo/demo.lua
tests/_quarto.yml
tests/basic.qmd'

SCHEMA_TREE='_extensions/demo/_extension.yml
_extensions/demo/_schema.yml
example.qmd'

MANIFEST_ONLY_TREE='_extensions/demo/_extension.yml
example.qmd'

NO_EXTENSION_TREE='README.md
template.qmd'

# A tests directory holding no document is not a suite.
EMPTY_SUITE_TREE='_extensions/demo/_extension.yml
tests/_quarto.yml'

# An installed copy under docs/ is not this repository's own extension.
INSTALLED_COPY_TREE='docs/_extensions/mcanouil/other/_extension.yml
README.md'

check 'a tests project with a document is a suite' 'suite' "$(mode_of "${SUITE_TREE}")"
check 'a schema without a suite is schema mode' 'schema' "$(mode_of "${SCHEMA_TREE}")"
check 'a manifest alone is conformance mode' 'conformance' "$(mode_of "${MANIFEST_ONLY_TREE}")"
check 'no extension manifest is render-only' 'render-only' "$(mode_of "${NO_EXTENSION_TREE}")"
check 'a tests project with no document is not a suite' 'conformance' "$(mode_of "${EMPTY_SUITE_TREE}")"
check 'an installed copy under docs is not an extension' 'render-only' "$(mode_of "${INSTALLED_COPY_TREE}")"

# The existing contract must not move: preflight-render.sh shares this file.
check 'project classification is unchanged' \
	'{"type":"project","project_path":"."}' \
	"$(printf '_quarto.yml\nindex.qmd\n' | classify_extension_tree)"
check 'document classification is unchanged' \
	'{"type":"document","qmd_files":["example.qmd"]}' \
	"$(printf 'example.qmd\n' | classify_extension_tree)"

# A template or example entry is never classified, so it must default rather
# than inherit whatever the last entry had.
check 'an unclassified entry defaults to render-only' 'render-only' \
	"$(printf '%s' '{"id":"o/r","type":"template"}' | jq -r '.test_mode // "render-only"')"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
