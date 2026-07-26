#!/usr/bin/env bash
# shellcheck shell=bash
# Extension processing functions for quarto-wizard

# Locates this module's siblings, the prefetch helper and the shared jq filter.
# main.sh exports it; the default keeps the module usable on its own, since the
# scripts do not run under `set -u` and an unset value would silently resolve
# those helpers against the filesystem root.
LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Fetch the full recursive tree for a ref, once per extension.
#
# Everything the run needs from the repository contents (template.qmd,
# example.qmd, and the extension manifests) is derived from this one response.
# Fetching it per question cost three identical round trips per extension.
#
# Arguments:
#   $1 - repo: Repository in owner/repo format
#   $2 - repo_branch: Branch or tag to query
# Returns:
#   Compact JSON array of {path, url} entries via stdout
fetch_repo_tree() {
  local repo="$1"
  local repo_branch="$2"

  gh api -X GET "repos/${repo}/git/trees/${repo_branch}?recursive=1" \
    --jq '[.tree[] | {path: .path, url: .url}]' 2>/dev/null || echo '[]'
}

# Report whether a path exists at the extension's root.
# Arguments:
#   $1 - tree: JSON array from fetch_repo_tree
#   $2 - path: Path relative to the repository root
tree_has_path() {
  local tree="$1"
  local path="$2"

  [[ $(echo "${tree}" | jq --arg p "${path}" 'map(select(.path == $p)) | length') -gt 0 ]]
}

# Extract contributes and quarto-required from _extension.yml files
# Arguments:
#   $1 - tree: JSON array from fetch_repo_tree
#   $2 - repo: Repository in owner/repo format, for diagnostics
#   $3 - repo_branch: Branch or tag queried, for diagnostics
#   $4 - repo_subdirectory: Optional subdirectory path (with trailing /)
# Returns:
#   JSON object with contributes array and quartoRequired string via stdout
extract_extension_manifest() {
  local tree="$1"
  local repo="$2"
  local repo_branch="$3"
  local repo_subdirectory="${4:-}"

  local extension_files
  extension_files=$(echo "${tree}" |
    jq -r --arg pattern "${repo_subdirectory}_extensions/.*/_extension\\.ya?ml$" \
      '.[] | select(.path | test($pattern)) | .url')

  if [[ -z "${extension_files}" ]]; then
    echo '{"contributes": null, "quartoRequired": null}'
    return
  fi

  # Extract both fields with yq per file; skip unparseable manifests with a warning
  # so one malformed _extension.yml does not abort the whole run.
  while IFS= read -r url; do
    local yaml_content parsed
    yaml_content=$(gh api "${url}" --jq '.content' | base64 --decode)
    if ! parsed=$(printf '%s' "${yaml_content}" | yq -o json '{
      "contributes": (.contributes | keys // []),
      "quartoRequired": (."quarto-required" // null)
    }' 2>/dev/null); then
      echo "::warning title=Invalid Extension Manifest::${repo}@${repo_branch} ${url}" >&2
      continue
    fi
    printf '%s\n' "${parsed}"
  done <<< "${extension_files}" | jq -s '{
    contributes: ([.[].contributes // empty] | add // [] | map(select(. != null)) | map(if type=="string" then sub("s$"; "") else . end) | unique),
    quartoRequired: (map(.quartoRequired) | map(select(. != null)) | if length > 0 then first else null end)
  }'
}

# Fetch every repository's metadata up front, batched into few GraphQL queries.
#
# The main loop is serial because it mutates git state, but the metadata each
# iteration opens with is read-only and independent, and dominates a nightly run
# where most extensions turn out to be unchanged.
#
# Entries sharing a repository (an extension living in a subdirectory) collapse
# to one query alias, and the phase prints per batch rather than only at the
# end: wrapped in a log group it looked like a stalled run for its whole
# duration.
#
# Arguments:
#   $1 - CSV entries, one per line
#   $2 - Cache directory
prefetch_repo_info() {
  local csv_entries="$1"
  local cache_dir="$2"

  echo "Prefetching repository metadata"
  mkdir -p "${cache_dir}"

  echo "${csv_entries}" |
    grep -v '^[[:space:]]*$' |
    cut -d'/' -f1,2 |
    sort -fu |
    bash "${LIB_DIR}/prefetch-repo-info.sh" "${cache_dir}"
}

# Read a prefetched record, falling back to a direct fetch when the prefetch
# missed it (a transient API failure, or an entry added since).
# Arguments:
#   $1 - repo: Repository in owner/repo format
#   $2 - Cache directory
read_repo_info() {
  local repo="$1"
  local cache_dir="$2"
  local cached="${cache_dir}/${repo//\//__}.json"

  if [[ -s "${cached}" ]]; then
    cat "${cached}"
    return
  fi

  gh repo view "${repo}" \
    --json name,nameWithOwner,owner,description,openGraphImageUrl,stargazerCount,licenseInfo,url,latestRelease,createdAt,updatedAt,pushedAt,repositoryTopics,defaultBranchRef \
    --jq "$(cat "${LIB_DIR}/repo-view.jq")"
}

# Main function to process extensions from CSV
# Uses global variables: CSV_ENTRIES, EXTENSIONS_DIR, COMMIT, DEBUG_MODE, BRANCH, FORCE_UPDATE
# Modifies global arrays: updated_extensions, skipped_extensions, outdated_extensions, valid_dirs
process_extensions() {
  local CSV_ENTRIES="$1"
  local previous_owner=""
  local previous_author=""

  local cache_dir
  cache_dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand cache_dir now, while it is still in scope
  trap "rm -rf '${cache_dir}'" RETURN
  prefetch_repo_info "${CSV_ENTRIES}" "${cache_dir}"

  while IFS=, read -r entry; do
    echo "::group::Processing entry: ${entry}"
    local repo
    repo=$(echo "${entry}" | cut -d'/' -f1,2)

    local repo_info
    repo_info=$(read_repo_info "${repo}" "${cache_dir}")

    local nameWithOwner owner
    nameWithOwner=$(echo "${repo_info}" | jq -r ".nameWithOwner")
    owner=$(echo "${repo_info}" | jq -r ".owner")

    if [[ "${repo,,}" != "${nameWithOwner}" ]]; then
      # Build the new entry, preserving subdirectory if present
      local subdirectory_suffix
      subdirectory_suffix=$(echo "${entry}" | cut -d'/' -f3-)
      local new_entry="${nameWithOwner}"
      if [[ -n "${subdirectory_suffix}" ]]; then
        new_entry="${nameWithOwner}/${subdirectory_suffix}"
      fi

      echo "::warning title=Renamed Repository::\"${entry}\" -> \"${new_entry}\""

      # Update the local CSV file in data/ (will be pushed to main at the end)
      sed -i "s|^${entry}$|${new_entry}|" "data/${CSV_FILE}"

      renamed_extensions+=("${entry} -> ${new_entry}")
      entry="${new_entry}"
    fi

    mkdir -p "${EXTENSIONS_DIR}/${nameWithOwner}"
    valid_dirs+=("${EXTENSIONS_DIR}/${nameWithOwner}")

    local author_json_file="${EXTENSIONS_DIR}/${owner}/author.json"
    local author_png_file="${EXTENSIONS_DIR}/${owner}/author"
    local extension_json_file="${EXTENSIONS_DIR}/${nameWithOwner}/extension.json"
    local extension_card_file="${EXTENSIONS_DIR}/${nameWithOwner}/extension.webp"

    local author update_author_json
    if [[ "${owner}" == "${previous_owner}" ]]; then
      author="${previous_author}"
    else
      local author_payload
      author_payload=$(gh api "users/${owner}")
      author=$(echo "${author_payload}" | jq -r ".name")
      if [[ -z "${author}" ]]; then
        author="${owner}"
      fi
      local author_updated_at
      author_updated_at=$(echo "${author_payload}" | jq -r ".updated_at")
      update_author_json=true
      if [[ -f "${author_json_file}" ]]; then
        local existing_author_updated_at
        existing_author_updated_at=$(jq -r ".updated_at // empty" "${author_json_file}")
        if [[ -n "${existing_author_updated_at}" && "${existing_author_updated_at}" == "${author_updated_at}" ]]; then
          echo "Skipping author.json for ${owner}: updated_at matches existing record (${existing_author_updated_at})"
          update_author_json=false
        fi
      fi
      if [[ "${update_author_json}" == "true" ]]; then
        echo "${author_payload}" > "${author_json_file}"
        git add "${author_json_file}" || echo "No changes detected, skipping commit"
        author_png_file=$(author_image_file "${author_png_file}" "${owner}")
        git add "${author_png_file}" || echo "No changes detected, skipping commit"
      fi
      previous_owner="${owner}"
      previous_author="${author}"
    fi

    repo_info=$(echo "${repo_info}" | jq --arg author "${author}" '. + {author: $author}')

    if [[ -f "${extension_json_file}" ]]; then
      local existing_updated_at current_updated_at
      existing_updated_at=$(jq -r ".[\"${entry,,}\"].updatedAt // empty" "${extension_json_file}")
      current_updated_at=$(echo "${repo_info}" | jq -r ".updatedAt")
      # A card is only ever stored when the download differed from GitHub's
      # generic placeholder, so a missing file is the sole retry signal.
      local missing_card=false
      if [[ ! -f "${extension_card_file}" ]]; then
        missing_card=true
      fi
      if [[ "${FORCE_UPDATE}" != "true" ]]; then
        if [[ -n "${existing_updated_at}" && "${existing_updated_at}" == "${current_updated_at}" && "${missing_card}" == false ]]; then
          echo "Skipping ${entry}: updatedAt matches existing record (${existing_updated_at})"
          skipped_extensions+=("${entry}")
          echo "::endgroup::"
          continue
        elif [[ "${missing_card}" == true ]]; then
          echo "Processing ${entry}: social card image missing"
        fi
      else
        echo "Force update enabled: processing ${entry} regardless of timestamps or card state."
      fi
    else
      echo "Processing ${entry}: JSON file does not exist, will create new record"
    fi

    local repo_subdirectory
    repo_subdirectory=$(echo "${entry}" | cut -d'/' -f3-)
    if [[ -n "${repo_subdirectory}" ]]; then
      repo_subdirectory="${repo_subdirectory}/"
    fi

    local default_branch repo_tag repo_branch
    default_branch=$(echo "${repo_info}" | jq -r '.defaultBranchRef')
    repo_tag=$(echo "${repo_info}" | jq -r ".latestRelease")
    if [[ "${repo_tag}" != "none" ]]; then
      repo_branch="${repo_tag}"
    else
      repo_branch="${default_branch}"
    fi

    local repo_tree
    repo_tree=$(fetch_repo_tree "${repo}" "${repo_branch}")

    # Presence of template.qmd and example.qmd at the extension root. The tree
    # already answers this, so no blob needs to be downloaded to find out.
    if tree_has_path "${repo_tree}" "${repo_subdirectory}template.qmd"; then
      repo_info=$(echo "${repo_info}" | jq '. + {template: true} | .repositoryTopics += ["template"]')
    else
      repo_info=$(echo "${repo_info}" | jq '. + {template: false}')
    fi

    if tree_has_path "${repo_tree}" "${repo_subdirectory}example.qmd"; then
      repo_info=$(echo "${repo_info}" | jq '. + {example: true} | .repositoryTopics += ["example"]')
    else
      repo_info=$(echo "${repo_info}" | jq '. + {example: false}')
    fi

    # Fetch latest commit
    local latest_commit
    latest_commit=$(gh api "repos/${repo}/commits/${default_branch}" --jq '.sha' 2>/dev/null || echo "")
    repo_info=$(echo "${repo_info}" | jq --arg latestCommit "${latest_commit}" '. + {latestCommit: $latestCommit}')

    # Extract contributes and quarto-required in single pass
    local manifest_data repo_contributes repo_quarto_required
    manifest_data=$(extract_extension_manifest "${repo_tree}" "${repo}" "${repo_branch}" "${repo_subdirectory}")
    repo_contributes=$(echo "${manifest_data}" | jq -c '.contributes')
    repo_quarto_required=$(echo "${manifest_data}" | jq -r '.quartoRequired')

    if [[ "${repo_contributes}" != "null" ]]; then
      repo_info=$(echo "${repo_info}" | jq --argjson contributes "${repo_contributes}" '. + {contributes: $contributes}')
    else
      repo_info=$(echo "${repo_info}" | jq '. + {contributes: null}')
    fi

    if [[ -n "${repo_quarto_required}" && "${repo_quarto_required}" != "null" ]]; then
      repo_info=$(echo "${repo_info}" | jq --arg quartoRequired "${repo_quarto_required}" '. + {quartoRequired: $quartoRequired}')
    else
      repo_info=$(echo "${repo_info}" | jq '. + {quartoRequired: null}')
    fi

    # Download and store the social card. The website derives every display
    # field from extension.json, so this is the only per-extension artefact
    # beyond the record itself.
    local entry_image stored_card
    entry_image=$(echo "${repo_info}" | jq -r '.openGraphImageUrl')
    stored_card=$(extension_image_file "${entry_image}" "${extension_card_file}" | tail -n 1)

    echo "${repo_info}" | jq --arg entry "${entry,,}" '{($entry): .}' >"${extension_json_file}"

    # Gather all files to stage and commit
    local files_to_commit=("${extension_json_file}")
    if [[ -n "${stored_card}" ]]; then
      files_to_commit+=("${stored_card}")
    fi
    if [[ "${owner}" != "${previous_owner}" && "${update_author_json}" == "true" ]]; then
      files_to_commit+=("${author_json_file}" "${author_png_file}")
    fi
    git_stage_and_commit "${files_to_commit[@]}"
    updated_extensions+=("${entry}")
    echo "::endgroup::"
  done < <(echo "$CSV_ENTRIES" | sort -f)
}
