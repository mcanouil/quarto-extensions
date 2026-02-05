#!/usr/bin/env bash
# shellcheck shell=bash
# Git operations for quarto-wizard

# Stage files and commit with optional push
# Uses global variables: COMMIT, DEBUG_MODE, BRANCH
# Arguments:
#   $@ - Files to stage and commit
git_stage_and_commit() {
  local files=("$@")
  local staged=false

  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      git add "${file}" 2>/dev/null && staged=true || echo "No changes detected for ${file}, skipping add"
    fi
  done

  if [[ "${staged}" == true ]]; then
    git commit --allow-empty -m "${COMMIT}"
    if [[ "${DEBUG_MODE}" == "false" ]]; then
      git push --force origin "${BRANCH}"
    else
      echo "Debug mode is enabled, skipping push"
    fi
  fi
}

# Clean up outdated extension directories
# Uses global variables: DEBUG_MODE, BRANCH
# Arguments:
#   $1 - Extensions directory path
#   $@ - Valid directory paths to keep
github_cleanup_extensions_dir() {
  echo "::group::Cleaning up extensions directory"
  local extensions_dir="${1}"
  shift
  local valid_dirs=("$@")

  # Remove outdated extension directories
  find "${extensions_dir}" -mindepth 2 -maxdepth 2 -type d | while read -r dir; do
    local keep=false
    for valid in "${valid_dirs[@]}"; do
      if [[ "${dir}" == "${valid}" ]]; then
        keep=true
        break
      fi
    done
    if [[ "${keep}" == false ]]; then
      echo "::notice title=Cleanup::Removing ${dir}"
      git rm -rf "${dir}"
      rm -rf "${dir}"
    fi
  done

  # Remove empty owner directories
  find "${extensions_dir}" -mindepth 1 -maxdepth 1 -type d | while read -r owner_dir; do
    if [[ -z $(find "${owner_dir}" -mindepth 1 -type d) ]]; then
      echo "::notice title=Cleanup::Removing empty owner directory ${owner_dir}"
      git rm -rf "${owner_dir}"
      rm -rf "${owner_dir}"
    fi
  done

  git commit --allow-empty -m "ci: cleanup outdated extensions directories"
  if [[ "${DEBUG_MODE}" == "false" ]]; then
    git push --force origin "${BRANCH}"
  else
    echo "Debug mode is enabled, skipping push"
  fi
  echo "::endgroup::"
}

# Push auto-fixed renamed entries in CSV to main branch via Contents API
# Uses global variables: DEBUG_MODE, GITHUB_REPOSITORY
# Arguments:
#   $1 - csv_file: Path relative to repo root (e.g., "extensions/quarto-extensions.csv")
#   $2 - renamed_list: Comma-separated list of "old -> new" rename descriptions
push_csv_renames_to_main() {
  local csv_file="$1"
  local renamed_list="$2"

  if [[ "${DEBUG_MODE}" == "true" ]]; then
    echo "Debug mode: skipping CSV push to main for renames: ${renamed_list}"
    return 0
  fi

  # Get current SHA from main branch
  local current_sha
  current_sha=$(gh api "repos/${GITHUB_REPOSITORY}/contents/${csv_file}?ref=main" --jq '.sha')
  if [[ -z "${current_sha}" ]]; then
    echo "::error title=Auto-Fix Failed::Could not fetch SHA for ${csv_file} on main"
    return 1
  fi

  # Read the locally updated CSV and base64-encode it
  local encoded_content
  encoded_content=$(base64 -w 0 < "data/${csv_file}")

  # Push via Contents API
  if gh api -X PUT "repos/${GITHUB_REPOSITORY}/contents/${csv_file}" \
    -f message="chore: auto-fix renamed repositories in CSV" \
    -f content="${encoded_content}" \
    -f sha="${current_sha}" \
    -f branch="main" > /dev/null 2>&1; then
    echo "::notice title=Auto-Fix Success::CSV updated on main with renames: ${renamed_list}"
    return 0
  else
    echo "::error title=Auto-Fix Failed::Could not push CSV updates to main"
    return 1
  fi
}
