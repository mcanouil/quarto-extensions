#!/usr/bin/env bash
# Tests for lib/extension.sh. Run directly: tests/extension.test.sh
#
# A stub gh answers with a fixed GraphQL response, so the tests run
# without network access or a token.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/extension.sh
source "${HERE}/../lib/extension.sh"

# shellcheck source=SCRIPTDIR/helpers.sh
source "${HERE}/helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

stub_gh "${work}"
mkdir -p "${work}/cache"

cat >"${work}/response.json" <<'JSON'
{
  "data": {
    "r0": {
      "name": "demo",
      "nameWithOwner": "owner/demo",
      "owner": {"login": "owner"},
      "description": "Demo.",
      "openGraphImageUrl": "https://example.com/card.png",
      "stargazerCount": 3,
      "licenseInfo": {"name": "MIT License"},
      "url": "https://github.com/owner/demo",
      "releases": {"nodes": [
        {"tagName": "v1.2.0", "url": "https://github.com/owner/demo/releases/tag/v1.2.0", "isPrerelease": false, "isDraft": false}
      ]},
      "refs": {"nodes": [{"name": "v1.3.0"}, {"name": "v1.2.0"}]},
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-02-01T00:00:00Z",
      "pushedAt": "2024-03-01T00:00:00Z",
      "defaultBranchRef": {"name": "main"},
      "repositoryTopics": {"nodes": []}
    }
  }
}
JSON

# A cache miss fetches the repository through the same query as the prefetch,
# so the record carries the same latest tag whichever path produced it.
info=$(PATH="${work}/bin:${PATH}" STUB_DIR="${work}" read_repo_info "owner/demo" "${work}/cache")
check 'a cache miss stores the latest tag by the same rule' \
	'v1.3.0' "$(jq -r '.latestRelease' <<<"${info}")"

# A stored record holds its fields under the lower-cased entry.
record="${work}/extension.json"
store() {
	jq -n --arg u "$1" --arg p "$2" --arg t "$3" \
		'{"owner/demo": {updatedAt: $u, pushedAt: $p, latestRelease: $t, latestReleaseUrl: null}}' >"${record}"
}
current='{"updatedAt":"2024-02-01T00:00:00Z","pushedAt":"2024-03-01T00:00:00Z","latestRelease":"v1.3.0","latestReleaseUrl":null}'

is_current() {
	if record_is_current "${record}" "owner/demo" "${current}"; then echo current; else echo stale; fi
}

store 2024-02-01T00:00:00Z 2024-03-01T00:00:00Z v1.3.0
check 'a record with the same dates and tag is current' 'current' "$(is_current)"

store 2024-02-01T00:00:00Z 2024-02-15T00:00:00Z v1.3.0
check 'a push without a change of updatedAt makes the record stale' 'stale' "$(is_current)"

store 2024-02-01T00:00:00Z 2024-03-01T00:00:00Z v1.2.0
check 'a different latest tag makes the record stale' 'stale' "$(is_current)"

store 2024-01-15T00:00:00Z 2024-03-01T00:00:00Z v1.3.0
check 'a change of updatedAt makes the record stale' 'stale' "$(is_current)"

# A release published on a tag that already exists changes no date or tag.
store 2024-02-01T00:00:00Z 2024-03-01T00:00:00Z v1.3.0
current=$(jq -c '.latestReleaseUrl = "https://github.com/owner/demo/releases/tag/v1.3.0"' <<<"${current}")
check 'a new release URL makes the record stale' 'stale' "$(is_current)"

echo '{"owner/other": {}}' >"${record}"
check 'a record without the entry is stale' 'stale' "$(is_current)"

# A stub gh that serves each manifest from $STUB_DIR/blobs/<url>, base64
# encoded as the contents API returns it. The tree uses the path as the url.
mkdir -p "${work}/manifest/bin"
cat >"${work}/manifest/bin/gh" <<'STUB'
#!/usr/bin/env bash
base64 <"${STUB_DIR}/blobs/$2"
STUB
chmod +x "${work}/manifest/bin/gh"

# Write a manifest into the stub.
# Arguments:
#   $1 - Path in the repository
#   stdin - YAML content
blob() {
	mkdir -p "$(dirname "${work}/manifest/blobs/$1")"
	cat >"${work}/manifest/blobs/$1"
}

# Arguments:
#   $@ - Paths in the repository tree
manifest() {
	local tree
	tree=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({path: ., url: .})')
	PATH="${work}/manifest/bin:${PATH}" STUB_DIR="${work}/manifest" \
		extract_extension_manifest "${tree}" "owner/demo" "main" ""
}

blob _extensions/demo/_extension.yml <<'YAML'
contributes:
  filters:
    - demo.lua
YAML
blob docs/_extensions/site/_extension.yml <<'YAML'
contributes:
  formats:
    html: {}
YAML

check 'extensions vendored outside the root _extensions are ignored' \
	'["filter"]' "$(manifest _extensions/demo/_extension.yml docs/_extensions/site/_extension.yml | jq -c '.contributes')"

blob diaquarto/_extensions/demo/_extension.yml <<'YAML'
contributes:
  filters:
    - demo.lua
YAML
blob vendor/diaquarto/_extensions/site/_extension.yml <<'YAML'
contributes:
  shortcodes:
    - site.lua
YAML

subdir_tree=$(jq -nc '["diaquarto/_extensions/demo/_extension.yml", "vendor/diaquarto/_extensions/site/_extension.yml"] | map({path: ., url: .})')
check 'an entry in a subdirectory reads only that subdirectory'"'"'s manifests' \
	'["filter"]' "$(PATH="${work}/manifest/bin:${PATH}" STUB_DIR="${work}/manifest" \
		extract_extension_manifest "${subdir_tree}" "owner/demo" "main" "diaquarto/" | jq -c '.contributes')"

blob _extensions/journal/_extension.yml <<'YAML'
contributes:
  formats:
    common:
      toc: true
    html+dark: {}
    pdf: {}
YAML
blob _extensions/slides/_extension.yml <<'YAML'
contributes:
  format:
    typst: {}
    html: {}
YAML
blob _extensions/both/_extension.yml <<'YAML'
contributes:
  formats:
    docx: {}
  format:
    pptx: {}
YAML

blob _extensions/odd/_extension.yml <<'YAML'
contributes:
  formats:
    true: {}
    1: {}
    html: {}
YAML

check 'format keys that YAML reads as booleans or numbers are skipped' \
	'["html"]' "$(manifest _extensions/odd/_extension.yml | jq -c '.formats')"
check 'base formats are merged across manifests, without variants or common' \
	'["html","pdf","typst"]' "$(manifest _extensions/journal/_extension.yml _extensions/slides/_extension.yml | jq -c '.formats')"
check 'the singular format key counts as a format contribution' \
	'["format"]' "$(manifest _extensions/slides/_extension.yml | jq -c '.contributes')"
check 'formats wins over format, as in Quarto' \
	'["docx"]' "$(manifest _extensions/both/_extension.yml | jq -c '.formats')"
check 'an extension without formats has an empty list' \
	'[]' "$(manifest _extensions/demo/_extension.yml | jq -c '.formats')"
check 'a repository without manifests has no formats' \
	'null' "$(manifest | jq -c '.formats')"

entries=$'alpha/one\nBeta/two\nmike/three'
check 'an empty filter keeps every entry' \
	"${entries}" "$(select_entries "${entries}" "")"
check 'a filter keeps the matching entries, ignoring case' \
	$'alpha/one\nBeta/two' "$(select_entries "${entries}" "^[a-l]")"
check 'a filter that matches nothing fails' \
	'failed' "$(select_entries "${entries}" "^z" 2>/dev/null || echo failed)"
check 'an invalid filter is reported as invalid' \
	'1' "$(select_entries "${entries}" "[a-l" 2>&1 >/dev/null | grep -c 'Invalid Entries Filter')"

finish
