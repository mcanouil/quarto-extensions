#!/usr/bin/env bash
# Tests for lib/extension.sh. Run directly: tests/extension.test.sh
#
# A stub gh answers every call with a fixed GraphQL response, so the tests run
# without network access or a token.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/../lib/extension.sh
source "${HERE}/../lib/extension.sh"

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

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin" "${work}/cache"
cat >"${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_DIR}/response.json"
STUB
chmod +x "${work}/bin/gh"

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
		'{"owner/demo": {updatedAt: $u, pushedAt: $p, latestRelease: $t}}' >"${record}"
}
current='{"updatedAt":"2024-02-01T00:00:00Z","pushedAt":"2024-03-01T00:00:00Z","latestRelease":"v1.3.0"}'

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

echo '{"owner/other": {}}' >"${record}"
check 'a record without the entry is stale' 'stale' "$(is_current)"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
