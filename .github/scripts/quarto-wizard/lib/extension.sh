#!/usr/bin/env bash
# shellcheck shell=bash
# Extension processing functions for quarto-wizard

# Extract contributes and quarto-required from _extension.yml files
# Arguments:
#   $1 - repo: Repository in owner/repo format
#   $2 - repo_branch: Branch or tag to query
#   $3 - repo_subdirectory: Optional subdirectory path (with trailing /)
# Returns:
#   JSON object with contributes array and quartoRequired string via stdout
extract_extension_manifest() {
  local repo="$1"
  local repo_branch="$2"
  local repo_subdirectory="${3:-}"

  local extension_files
  extension_files=$(gh api \
    -X GET "repos/${repo}/git/trees/${repo_branch}?recursive=1" \
    --jq ".tree[] | select(.path | test(\"${repo_subdirectory}_extensions/.*/_extension\\\\.ya?ml$\")) | .url")

  if [[ -z "${extension_files}" ]]; then
    echo '{"contributes": null, "quartoRequired": null}'
    return
  fi

  # Extract both fields with yq in single pass, then aggregate with jq
  echo "${extension_files}" |
    while read -r url; do
      gh api "${url}" --jq '.content' | base64 --decode | yq -o json '{
        "contributes": (.contributes | keys // []),
        "quartoRequired": (."quarto-required" // null)
      }'
    done | jq -s '{
      contributes: (map(.contributes) | add | map(select(. != null)) | map(if type=="string" then sub("s$"; "") else . end) | unique),
      quartoRequired: (map(.quartoRequired) | map(select(. != null)) | if length > 0 then first else null end)
    }'
}

# Main function to process extensions from CSV
# Uses global variables: CSV_ENTRIES, EXTENSIONS_DIR, COMMIT, DEBUG_MODE, BRANCH, FORCE_UPDATE
# Modifies global arrays: updated_extensions, skipped_extensions, outdated_extensions, valid_dirs
process_extensions() {
  echo "::group::Processing Extensions"
  local CSV_ENTRIES="$1"
  local previous_owner=""
  local previous_author=""

  while IFS=, read -r entry; do
    echo "::group::Processing entry: ${entry}"
    local repo
    repo=$(echo "${entry}" | cut -d'/' -f1,2)

    local repo_info
    repo_info=$(gh repo view "${repo}" \
      --json name,nameWithOwner,owner,description,openGraphImageUrl,stargazerCount,licenseInfo,url,latestRelease,createdAt,updatedAt,pushedAt,repositoryTopics,defaultBranchRef \
      --jq '{
        name: .name,
        title: (.name | split("-|_"; "") | map(select(. != "quarto" and . != "template")) | join(" ") | ascii_upcase),
        nameWithOwner: (.nameWithOwner | ascii_downcase),
        owner: (.owner.login | ascii_downcase),
        description: (if .description == "" then "No description available." else .description end),
        openGraphImageUrl: .openGraphImageUrl,
        stargazerCount: (.stargazerCount // 0),
        licenseInfo: (.licenseInfo.name // "none"),
        url: .url,
        latestRelease: (.latestRelease.tagName // "none"),
        latestReleaseUrl: (.latestRelease.url // null),
        createdAt: .createdAt,
        updatedAt: .updatedAt,
        pushedAt: .pushedAt,
        defaultBranchRef: .defaultBranchRef.name,
        repositoryTopics: (if .repositoryTopics == null then [] else
        [.repositoryTopics[].name |
          sub("^quarto-"; "") |
          sub("-template[s]*"; "") |
          if test("filters$|formats$|journals$|templates|shortcodes$|extensions$") then sub("s$"; "") else . end |
          sub("reveal-js"; "reveal.js") |
          sub("revealjs"; "reveal.js") |
          select(test("quarto|extension|template|^pub$") | not)] | unique
        end)
      }')

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
    local extension_png_file="${EXTENSIONS_DIR}/${nameWithOwner}/extension.png"
    local extension_yaml_file="${EXTENSIONS_DIR}/${nameWithOwner}/extension.yml"

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
      local files=("${extension_json_file}" "${extension_png_file}" "${extension_yaml_file}")
      local all_exist=true
      for file in "${files[@]}"; do
        [[ -f "${file}" ]] || all_exist=false
      done
      local has_placeholder=false
      if [[ -f "${extension_yaml_file}" ]]; then
        if grep -q 'image: "/assets/media/github-placeholder.png"' "${extension_yaml_file}"; then
          has_placeholder=true
        fi
      fi
      if [[ "${FORCE_UPDATE}" != "true" ]]; then
        if [[ -n "${existing_updated_at}" && "${existing_updated_at}" == "${current_updated_at}" && "${all_exist}" == true && "${has_placeholder}" == false ]]; then
          echo "Skipping ${entry}: updatedAt matches existing record (${existing_updated_at})"
          skipped_extensions+=("${entry}")
          echo "::endgroup::"
          continue
        elif [[ "${has_placeholder}" == true ]]; then
          echo "Processing ${entry}: extension YAML contains placeholder image"
        fi
      else
        echo "Force update enabled: processing ${entry} regardless of timestamps or placeholder."
      fi
    else
      echo "Processing ${entry}: JSON file does not exist, will create new record"
    fi

    local repo_subdirectory
    repo_subdirectory=$(echo "${entry}" | cut -d'/' -f3-)
    local repo_recursive=""
    if [[ -n "${repo_subdirectory}" ]]; then
      repo_subdirectory="${repo_subdirectory}/"
      repo_recursive="?recursive=1"
    fi

    local default_branch repo_tag repo_branch
    default_branch=$(echo "${repo_info}" | jq -r '.defaultBranchRef')
    repo_tag=$(echo "${repo_info}" | jq -r ".latestRelease")
    if [[ "${repo_tag}" != "none" ]]; then
      repo_branch="${repo_tag}"
    else
      repo_branch="${default_branch}"
    fi

    # Fetch template.qmd
    local repo_template
    repo_template=$(gh api \
      -X GET "repos/${repo}/git/trees/${repo_branch}${repo_recursive}" \
      --jq ".tree[] | select(.path | endswith(\"${repo_subdirectory}template.qmd\")) | .url | @sh" | xargs -I {} gh api -X GET {} --jq ".content")
    if [[ -n "${repo_template}" ]]; then
      repo_info=$(echo "${repo_info}" | jq '. + {template: true} | .repositoryTopics += ["template"]')
    else
      repo_info=$(echo "${repo_info}" | jq '. + {template: false}')
    fi

    # Fetch example.qmd
    local repo_example
    repo_example=$(gh api \
      -X GET "repos/${repo}/git/trees/${repo_branch}${repo_recursive}" \
      --jq ".tree[] | select(.path | endswith(\"${repo_subdirectory}example.qmd\")) | .url | @sh" | xargs -I {} gh api -X GET {} --jq ".content")
    if [[ -n "${repo_example}" ]]; then
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
    manifest_data=$(extract_extension_manifest "${repo}" "${repo_branch}" "${repo_subdirectory}")
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

    # Extract fields for YAML generation
    local entry_title entry_created entry_updated entry_url entry_topics entry_contributes
    local entry_license entry_stars entry_image entry_author entry_template entry_example
    local entry_description entry_release yaml_usage_body entry_quarto_required

    entry_title=$(echo "${repo_info}" | jq -r '.title')
    entry_created=$(echo "${repo_info}" | jq -r '.createdAt')
    entry_updated=$(echo "${repo_info}" | jq -r '.pushedAt')
    entry_url=$(echo "${repo_info}" | jq -r '.url')
    entry_topics=$(echo "${repo_info}" | jq -r '.repositoryTopics' | jq -c 'unique')
    entry_contributes=$(echo "${repo_info}" | jq -r '.contributes' | jq -c 'unique')
    entry_license=$(echo "${repo_info}" | jq -r '.licenseInfo')
    entry_stars=$(echo "${repo_info}" | jq -r '.stargazerCount')
    entry_image=$(echo "${repo_info}" | jq -r '.openGraphImageUrl')
    entry_author=$(echo "${repo_info}" | jq -r '.author')
    entry_template=$(echo "${repo_info}" | jq -r '.template')
    entry_example=$(echo "${repo_info}" | jq -r '.example')
    entry_quarto_required=$(echo "${repo_info}" | jq -r '.quartoRequired // empty')
    entry_description=$(echo "${repo_info}" | jq -r '.description')
    entry_description=$(echo "${entry_description}" | sed 's/^[[:space:]]*//')
    entry_description=$(echo "${entry_description}" | sed -E 's/([^`])(<[^<>]+>)([^`])/\1`\2`\3/g')
    entry_description=$(escape_bash "${entry_description}")
    entry_release=$(echo "${repo_info}" | jq -r '.latestRelease')
    yaml_usage_body="${nameWithOwner}"

    if [[ "${entry_release}" == "none" ]]; then
      local entry_commit
      entry_commit=$(echo "${repo_info}" | jq -r '.latestCommit')
      # yaml_usage_body="${nameWithOwner}@${entry_commit:0:7}" # Quarto CLI does not support commit SHAs yet
    else
      local entry_release_url
      entry_release_url=$(echo "${repo_info}" | jq -r '.latestReleaseUrl')
      yaml_usage_body="${nameWithOwner}@${entry_release}"
      entry_release=$(echo "${entry_release}" | sed 's/^[^0-9]*//')
      entry_release="[${entry_release}](${entry_release_url})"
    fi

    local clean_extension_png_file
    clean_extension_png_file=$(extension_image_file "${entry_image}" "${extension_png_file}" | tail -n 1)

    generate_extension_yaml \
      "${extension_yaml_file}" "${entry_title}" "${clean_extension_png_file}" "${entry_url}" \
      "${entry_author}" "${owner}" "${entry_created}" "${entry_updated}" "${entry_topics}" \
      "${entry_license}" "${entry_stars}" "${entry_release}" "${entry_description}" \
      "${yaml_usage_body}" "${entry_template}" "${entry_example}" "${entry_contributes}" \
      "${entry_quarto_required}"

    echo "${repo_info}" | jq --arg entry "${entry,,}" '{($entry): .}' > "${extension_json_file}"

    # Gather all files to stage and commit
    local files_to_commit=("${extension_json_file}" "${extension_yaml_file}" "${clean_extension_png_file}")
    if [[ "${owner}" != "${previous_owner}" && "${update_author_json}" == "true" ]]; then
      files_to_commit+=("${author_json_file}" "${author_png_file}")
    fi
    git_stage_and_commit "${files_to_commit[@]}"
    updated_extensions+=("${entry}")
    echo "::endgroup::"
  done < <(echo "$CSV_ENTRIES" | sort -f)
  echo "::endgroup::"
}
