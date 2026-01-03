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
