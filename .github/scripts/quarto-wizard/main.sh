#!/usr/bin/env bash
# shellcheck shell=bash
# Main entry point for quarto-wizard extension processing
set -e

# Determine script directory for sourcing modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules
# shellcheck source=lib/constants.sh
source "${SCRIPT_DIR}/lib/constants.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/image.sh
source "${SCRIPT_DIR}/lib/image.sh"
# shellcheck source=lib/yaml.sh
source "${SCRIPT_DIR}/lib/yaml.sh"
# shellcheck source=lib/git.sh
source "${SCRIPT_DIR}/lib/git.sh"
# shellcheck source=lib/extension.sh
source "${SCRIPT_DIR}/lib/extension.sh"

# Apply defaults from constants if environment variables are not set
DEBUG_MODE="${DEBUG_MODE:-${DEFAULT_DEBUG_MODE}}"
FORCE_UPDATE="${FORCE_UPDATE:-${DEFAULT_FORCE_UPDATE}}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-${DEFAULT_EXTENSIONS_DIR}}"
JSON_FILE="${JSON_FILE:-${DEFAULT_JSON_FILE}}"
BRANCH="${BRANCH:-${DEFAULT_BRANCH}}"
COMMIT="${COMMIT:-${DEFAULT_COMMIT}}"
CSV_FILE="${CSV_FILE:-${DEFAULT_CSV_FILE}}"

# Initialise directories
mkdir -p "${EXTENSIONS_DIR}"

# Initialise tracking arrays (used by process_extensions)
updated_extensions=()
skipped_extensions=()
outdated_extensions=()
renamed_extensions=()
valid_dirs=()

# Load CSV entries based on debug mode
if [[ "${DEBUG_MODE}" == "true" ]]; then
  CSV_ENTRIES=$(head -n 5 "data/${CSV_FILE}")
else
  CSV_ENTRIES=$(cat "data/${CSV_FILE}")
fi

# Process all extensions
process_extensions "${CSV_ENTRIES}"

# Merge all extension.json files into single quarto-extensions.json
find "${EXTENSIONS_DIR}" -type f -path "${EXTENSIONS_DIR}/*/*/extension.json" -print0 | xargs -0 cat | jq -s 'add' > "${JSON_FILE}"
git_stage_and_commit "${JSON_FILE}"

# Clean up outdated directories
github_cleanup_extensions_dir "${EXTENSIONS_DIR}" "${valid_dirs[@]}"

# Push renamed entries to main branch CSV
if [[ ${#renamed_extensions[@]} -gt 0 ]]; then
  renamed_list=$(printf '%s,' "${renamed_extensions[@]}" | sed 's/,$//')
  push_csv_renames_to_main "${CSV_FILE}" "${renamed_list}" || true
fi

# Output results to GitHub Actions
{
  echo "updated-count=${#updated_extensions[@]}"
  echo "skipped-count=${#skipped_extensions[@]}"
  echo "outdated-count=${#outdated_extensions[@]}"
  echo "renamed-count=${#renamed_extensions[@]}"
  echo "updated-extensions=$(printf '%s,' "${updated_extensions[@]}" | sed 's/,$//')"
  echo "skipped-extensions=$(printf '%s,' "${skipped_extensions[@]}" | sed 's/,$//')"
  echo "outdated-extensions=$(printf '%s,' "${outdated_extensions[@]}" | sed 's/,$//')"
  echo "renamed-extensions=$(printf '%s,' "${renamed_extensions[@]}" | sed 's/,$//')"
} >> "${GITHUB_OUTPUT}"

echo "::notice title=Updated Extensions::Count: ${#updated_extensions[@]}"
if [[ ${#renamed_extensions[@]} -gt 0 ]]; then
  echo "::notice title=Renamed Extensions (Auto-Fixed)::Count: ${#renamed_extensions[@]}"
fi
if [[ ${#outdated_extensions[@]} -gt 0 ]]; then
  echo "::error title=Outdated Extensions::Count: ${#outdated_extensions[@]}"
  exit 1
fi
