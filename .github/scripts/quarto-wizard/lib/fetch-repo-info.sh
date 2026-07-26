#!/usr/bin/env bash
set -uo pipefail

# Fetch one repository's metadata into the prefetch cache.
#
# Invoked by xargs from prefetch_repo_info, one process per repository, so it
# takes everything it needs as arguments and never touches shared state. A
# failure here is not fatal: the main loop falls back to fetching inline.
#
# Arguments:
#   $1 - CSV entry (owner/repo, optionally with a trailing subdirectory)
#   $2 - Cache directory

entry="${1:?entry required}"
cache_dir="${2:?cache directory required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jq_filter="${script_dir}/repo-view.jq"

repo="$(echo "${entry}" | cut -d'/' -f1,2)"
output="${cache_dir}/${repo//\//__}.json"

[[ -f "${output}" ]] && exit 0

fields="name,nameWithOwner,owner,description,openGraphImageUrl,stargazerCount"
fields="${fields},licenseInfo,url,latestRelease,createdAt,updatedAt,pushedAt"
fields="${fields},repositoryTopics,defaultBranchRef"

if ! gh repo view "${repo}" --json "${fields}" --jq "$(cat "${jq_filter}")" >"${output}.tmp" 2>/dev/null; then
  rm -f "${output}.tmp"
  exit 0
fi

# Only publish a complete file, so a truncated write can never be read as a
# valid record by the main loop.
mv "${output}.tmp" "${output}"
