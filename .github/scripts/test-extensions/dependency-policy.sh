#!/usr/bin/env bash
set -euo pipefail

# Validate dependency manifests for risky dependency sources.
# Inputs (env): EXT_ID, DEP_POLICY_ALLOWLIST_FILE (optional).
# Inputs (cwd): dependency files such as requirements.txt, uv.lock, renv.lock.

allowlist_file="${DEP_POLICY_ALLOWLIST_FILE:-}"
if [[ -z "${allowlist_file}" ]]; then
  allowlist_file="${GITHUB_WORKSPACE:-$(pwd)}/.github/scripts/test-extensions/dependency-policy-allowlist.txt"
fi

is_allowlisted=false
if [[ -f "${allowlist_file}" ]] && [[ -n "${EXT_ID:-}" ]]; then
  if grep -Fxq "${EXT_ID}" "${allowlist_file}"; then
    is_allowlisted=true
  fi
fi

if [[ "${is_allowlisted}" == "true" ]]; then
  echo "Dependency policy: ${EXT_ID} is allowlisted, skipping strict source checks."
  exit 0
fi

errors=0

check_text_file_for_patterns() {
  local file="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -Eq "${pattern}" "${file}"; then
      echo "::error::Dependency policy violation in ${file}. Matched pattern '${pattern}'."
      errors=1
    fi
  done
}

if [[ -f requirements.txt ]]; then
  check_text_file_for_patterns requirements.txt \
    '(^|\s)(git\+|https?://|ssh://|svn\+|hg\+|bzr\+)' \
    '(^|\s)-e(\s|$)' \
    '(^|\s)--index-url(\s|=)' \
    '(^|\s)--extra-index-url(\s|=)'
fi

if [[ -f uv.lock ]]; then
  # Only flag VCS and direct-URL sources; registry URLs (https://pypi.org/...) are legitimate.
  check_text_file_for_patterns uv.lock \
    'git\+' \
    'ssh://' \
    '^source\s*=\s*\{[^}]*(url|git)\s*=' \
    '^source\s*=\s*\{[^}]*editable\s*='
fi

if [[ -f renv.lock ]]; then
  if jq -e '
    [
      (.Packages // {})
      | to_entries[]
      | .value
      | select(
          ((.Source // "") | ascii_downcase) as $s
          | ($s == "git" or $s == "github" or $s == "gitlab" or $s == "bitbucket" or $s == "url")
        )
    ]
    | length > 0
  ' renv.lock >/dev/null 2>&1; then
    echo "::error::Dependency policy violation in renv.lock. Non-registry package source detected."
    errors=1
  fi
fi

if [[ "${errors}" -ne 0 ]]; then
  echo "::error::Dependency source policy check failed for ${EXT_ID:-unknown-extension}."
  exit 1
fi

echo "Dependency source policy check passed for ${EXT_ID:-unknown-extension}."
