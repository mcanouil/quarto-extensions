#!/usr/bin/env bash
set -euo pipefail

# Flag added repositories without a release or tag, and note those whose
# releases and tags hold no stable version.
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT, GITHUB_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LATEST_TAG_LIB="${SCRIPT_DIR}/../quarto-wizard/lib"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Print the latest stable tag of a repository as JSON, or null when no release
# or tag is a stable version. Fail when GitHub cannot be reached, so that the
# caller can skip the advisory note.
# Arguments:
#   $1 - owner/repo
latest_stable_tag() {
	local repo="$1" releases tags
	releases=$(retry 3 2 gh api "repos/${repo}/releases?per_page=100" \
		--jq '[.[] | {tagName: .tag_name, url: .html_url, isPrerelease: .prerelease, isDraft: .draft}]') || return 1
	tags=$(retry 3 2 gh api "repos/${repo}/tags?per_page=100" --jq '[.[].name]') || return 1
	jq -nc -L "${LATEST_TAG_LIB}" \
		--argjson releases "${releases}" --argjson tags "${tags}" \
		'include "latest-tag"; {releases: $releases, tags: $tags} | latest_tag'
}

while IFS=, read -r entry; do
	repo=$(entry_repo "${entry}")
	repo_release=$(gh repo view --json latestRelease "${repo}" --jq ".latestRelease")
	if [[ -z "${repo_release}" ]]; then
		repo_tags=$(gh api "repos/${repo}/tags" --jq "length" 2>/dev/null || echo 0)
		if [[ "${repo_tags:-0}" -eq 0 ]]; then
			add_error "${entry}" "Repository is missing release/tag."
			continue
		fi
	fi
	stable_tag=$(latest_stable_tag "${repo}") || continue
	if [[ "${stable_tag}" == "null" ]]; then
		add_note "${entry}" "No stable version, such as 1.2.3 or v1.2.3, was found among the latest 100 releases and tags. Quarto Wizard will not offer updates for this extension until one is."
	fi
done < <(read_diff_entries)

write_check_outputs
fail_if_errors
