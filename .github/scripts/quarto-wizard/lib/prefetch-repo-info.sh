#!/usr/bin/env bash
set -uo pipefail

# Fetch every repository's metadata into the prefetch cache, in batches.
#
# One `gh repo view` per repository meant ~350 GraphQL round trips per run, each
# paying process startup and each counting towards GitHub's secondary rate
# limits, which throttled the whole phase to around ten minutes. Aliasing many
# repositories into a single query turns that into a handful of requests.
#
# A failure here is never fatal: extension.sh falls back to fetching inline for
# any repository missing from the cache.
#
# Arguments:
#   $1 - Cache directory
# Input:
#   Repositories in owner/repo format on stdin, one per line
# Output:
#   One progress line per batch via stdout

cache_dir="${1:?cache directory required}"
batch_size="${PREFETCH_BATCH_SIZE:-50}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
view_filter="$(cat "${script_dir}/repo-view.jq")"

mkdir -p "${cache_dir}"

# GraphQL returns topics as a connection and omits an empty description, where
# `gh repo view --json` returns a flat list and an empty string. Reshaping here
# keeps repo-view.jq the single definition of a record, shared with the inline
# fallback.
normalise='{
  name: .name,
  nameWithOwner: .nameWithOwner,
  owner: .owner,
  description: (.description // ""),
  openGraphImageUrl: .openGraphImageUrl,
  stargazerCount: .stargazerCount,
  licenseInfo: .licenseInfo,
  url: .url,
  latestRelease: .latestRelease,
  createdAt: .createdAt,
  updatedAt: .updatedAt,
  pushedAt: .pushedAt,
  defaultBranchRef: .defaultBranchRef,
  repositoryTopics: [.repositoryTopics.nodes[].topic | {name: .name}]
}'

fragment='fragment RepoFields on Repository {
  name
  nameWithOwner
  owner { login }
  description
  openGraphImageUrl
  stargazerCount
  licenseInfo { name }
  url
  latestRelease { tagName url }
  createdAt
  updatedAt
  pushedAt
  defaultBranchRef { name }
  repositoryTopics(first: 20) { nodes { topic { name } } }
}'

# Write one batch of repositories to the cache.
#
# Arguments:
#   $@ - Repositories in owner/repo format
fetch_batch() {
  local repos=("$@")

  local query="query {"
  local bases=()
  local index=0
  local repo owner name
  for repo in "${repos[@]}"; do
    owner="${repo%%/*}"
    name="${repo##*/}"
    query+=$'\n'"  r${index}: repository(owner: \"${owner}\", name: \"${name}\") { ...RepoFields }"
    bases+=("${repo//\//__}")
    index=$((index + 1))
  done
  query+=$'\n''}'$'\n'"${fragment}"

  # A repository that has been deleted or made private resolves to null and
  # makes gh exit non-zero, while the rest of the batch still comes back, so the
  # response is parsed regardless of exit status.
  local response
  response=$(gh api graphql -f query="${query}" 2>/dev/null)
  if [[ -z "${response}" ]]; then
    return
  fi

  local names_json
  names_json=$(printf '%s\n' "${bases[@]}" | jq -R . | jq -s -c .)

  # Emitted as TSV of destination path and record, so one jq pass covers the
  # whole batch; tojson has already escaped anything @tsv would mangle.
  local path record
  while IFS=$'\t' read -r path record; do
    printf '%s\n' "${record}" > "${path}"
  done < <(
    printf '%s' "${response}" | jq -r \
      --argjson names "${names_json}" \
      --arg dir "${cache_dir}" "
      (.data // {}) | to_entries[] | select(.value != null) |
      [
        (\$dir + \"/\" + \$names[(.key | ltrimstr(\"r\") | tonumber)] + \".json\"),
        (.value | ${normalise} | ${view_filter} | tojson)
      ] | @tsv
    " 2>/dev/null
  )
}

repos=()
while IFS= read -r repo; do
  # Anything unexpected is left to the inline fallback rather than interpolated
  # into a GraphQL query.
  if [[ ! "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    continue
  fi
  repos+=("${repo}")
done

total=${#repos[@]}
if [[ "${total}" -eq 0 ]]; then
  echo "No repositories to prefetch."
  exit 0
fi

fetched=0
for ((start = 0; start < total; start += batch_size)); do
  fetch_batch "${repos[@]:start:batch_size}"
  fetched=$((start + batch_size))
  if [[ "${fetched}" -gt "${total}" ]]; then
    fetched="${total}"
  fi
  echo "Prefetched ${fetched}/${total} repositories."
done
