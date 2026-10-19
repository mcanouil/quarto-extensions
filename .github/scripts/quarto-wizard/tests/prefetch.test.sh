#!/usr/bin/env bash
# Tests for lib/prefetch-repo-info.sh. Run directly: tests/prefetch.test.sh
#
# A stub gh answers the GraphQL query with a fixed response, so the tests run
# without network access or a token.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib"

# shellcheck source=SCRIPTDIR/helpers.sh
source "${HERE}/helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

stub_gh "${work}"

# A repository where the latest release marker (v1.2.0) is not the highest
# version: v1.3.0 is a plain tag and v2.0.0 a release flagged as a prerelease.
cat >"${work}/response.json" <<'JSON'
{
  "data": {
    "r0": {
      "name": "demo",
      "nameWithOwner": "Owner/demo",
      "owner": {"login": "Owner"},
      "description": "Demo.",
      "openGraphImageUrl": "https://example.com/card.png",
      "stargazerCount": 3,
      "licenseInfo": {"name": "MIT License"},
      "url": "https://github.com/Owner/demo",
      "latestRelease": {"tagName": "v1.2.0", "url": "https://github.com/Owner/demo/releases/tag/v1.2.0"},
      "releases": {"nodes": [
        {"tagName": "v2.0.0", "url": "https://github.com/Owner/demo/releases/tag/v2.0.0", "isPrerelease": true, "isDraft": false},
        {"tagName": "v1.2.0", "url": "https://github.com/Owner/demo/releases/tag/v1.2.0", "isPrerelease": false, "isDraft": false}
      ]},
      "refs": {"nodes": [{"name": "v2.0.0"}, {"name": "v1.3.0"}, {"name": "v1.2.0"}, {"name": "nightly"}]},
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-02-01T00:00:00Z",
      "pushedAt": "2024-03-01T00:00:00Z",
      "defaultBranchRef": {"name": "main"},
      "repositoryTopics": {"nodes": []}
    },
    "r1": {
      "name": "bare",
      "nameWithOwner": "owner/bare",
      "owner": {"login": "owner"},
      "description": null,
      "openGraphImageUrl": "https://example.com/card.png",
      "stargazerCount": 0,
      "licenseInfo": null,
      "url": "https://github.com/owner/bare",
      "latestRelease": null,
      "releases": {"nodes": []},
      "refs": {"nodes": [{"name": "nightly"}]},
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-02-01T00:00:00Z",
      "pushedAt": "2024-03-01T00:00:00Z",
      "defaultBranchRef": {"name": "main"},
      "repositoryTopics": {"nodes": []}
    }
  }
}
JSON

printf 'owner/demo\nowner/bare\n' |
	PATH="${work}/bin:${PATH}" STUB_DIR="${work}" bash "${LIB}/prefetch-repo-info.sh" "${work}/cache" >/dev/null

demo="${work}/cache/owner__demo.json"
bare="${work}/cache/owner__bare.json"

check 'stores the highest stable version, not the release marker' \
	'v1.3.0' "$(jq -r '.latestRelease' "${demo}")"
check 'a tag without a release has no release URL' \
	'null' "$(jq -r '.latestReleaseUrl' "${demo}")"
check 'stores "none" when no tag qualifies' \
	'none' "$(jq -r '.latestRelease' "${bare}")"
check 'keeps pushedAt for the skip check' \
	'2024-03-01T00:00:00Z' "$(jq -r '.pushedAt' "${demo}")"
check 'asks GitHub for the releases' \
	'1' "$(grep -c 'releases(first: 100' "${work}/query")"
check 'asks GitHub for the tags' \
	'1' "$(grep -c 'refs(refPrefix: "refs/tags/", first: 100' "${work}/query")"

finish
