#!/usr/bin/env bash
set -euo pipefail

# Build the test matrix for the test-extensions workflow.
# Inputs (env): DEBUG, BATCH_SIZE, GH_TOKEN (for gh api calls)
# Inputs (env, debug only): REPO_OWNER (filters to same-owner extensions)
# Outputs (to GITHUB_OUTPUT): matrix, skipped

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

if [[ ! "${DEBUG}" =~ ^(true|false)$ ]]; then
  echo "::error::Invalid debug value: '${DEBUG}'. Expected 'true' or 'false'."
  exit 1
fi

if [[ ! "${BATCH_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid batch_size value: '${BATCH_SIZE}'. Expected a positive integer."
  exit 1
fi

extensions_json=$(cat quarto-extensions.json)
if [[ "${DEBUG}" == "true" ]]; then
  if [[ -z "${REPO_OWNER:-}" ]]; then
    echo "::error::REPO_OWNER is not set."
    exit 1
  fi
  owner_prefix="${REPO_OWNER}/"
  echo "Debug mode: filtering extensions to owner '${REPO_OWNER}'."
  extensions_json=$(echo "${extensions_json}" | jq -c --arg pfx "${owner_prefix}" '
    with_entries(select(.key | startswith($pfx)))
  ')
fi
entries_phase_a=$(echo "${extensions_json}" | jq -c '
  to_entries
  | map(
      if .value.template == true then {id: .key, type: "template"}
      elif .value.example == true then {id: .key, type: "example"}
      else empty
      end
    )
')

phase_b_entries_file=$(mktemp)
skipped_file=$(mktemp)
trees_dir=$(mktemp -d)
trap 'rm -rf "${trees_dir}"; rm -f "${phase_b_entries_file}" "${skipped_file}"' EXIT
: >"${phase_b_entries_file}"
: >"${skipped_file}"

phase_b_candidates=$(echo "${extensions_json}" | jq -c '
  to_entries
  | map(select(.value.example == false and .value.template == false) | {id: .key, default_branch: .value.defaultBranchRef})
')
if [[ "${DEBUG}" == "true" ]]; then
  phase_b_candidates=$(echo "${phase_b_candidates}" | jq -c '.[0:50]')
fi

# Phase B: fetch repository trees in parallel batches

candidate_count=$(echo "${phase_b_candidates}" | jq 'length')

fetch_tree() {
  local idx="$1" id="$2" default_branch="$3" output_dir="$4"
  local owner repo
  owner=$(echo "${id}" | cut -d'/' -f1)
  repo=$(echo "${id}" | cut -d'/' -f2)

  if [[ ! "${owner}" =~ ^[A-Za-z0-9_.-]+$ ]] || [[ ! "${repo}" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || [[ ! "${default_branch}" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    touch "${output_dir}/${idx}.failed"
    return
  fi

  if full_tree=$(retry 3 2 gh api "repos/${owner}/${repo}/git/trees/${default_branch}?recursive=1" \
    --jq '.tree[]? | .path' 2>/dev/null); then
    if [[ -n "${full_tree}" ]]; then
      printf '%s\n' "${full_tree}" >"${output_dir}/${idx}.tree"
    else
      touch "${output_dir}/${idx}.empty"
    fi
  else
    touch "${output_dir}/${idx}.failed"
  fi
}
while IFS=$'\t' read -r idx id branch; do
  fetch_tree "${idx}" "${id}" "${branch}" "${trees_dir}" &
  # Limit to 20 concurrent jobs
  if (($(jobs -r | wc -l) >= 20)); then
    wait -n
  fi
done < <(echo "${phase_b_candidates}" | jq -r 'to_entries[] | "\(.key)\t\(.value.id)\t\(.value.default_branch)"')
wait

find_best_project_path() {
  local best_path="" best_depth=999
  while IFS= read -r qpath; do
    local dir
    dir=$(dirname "${qpath}")
    if [[ "${dir}" =~ (^|/)tests(/|$) ]] || [[ "${dir}" =~ (^|/)examples(/|$) ]]; then
      continue
    fi
    if [[ "${dir}" == "." ]]; then
      echo "."
      return
    fi
    if [[ "${dir}" == "docs" ]] && [[ "${best_depth}" -gt 1 ]]; then
      best_path="docs"
      best_depth=1
      continue
    fi
    local depth slashes
    slashes="${dir//[!\/]/}"
    depth=$(( ${#slashes} + 1 ))
    if [[ "${depth}" -lt "${best_depth}" ]]; then
      best_path="${dir}"
      best_depth="${depth}"
    fi
  done
  if [[ -n "${best_path}" ]]; then
    echo "${best_path}"
  fi
}

mapfile -t candidate_ids < <(echo "${phase_b_candidates}" | jq -r '.[].id')

for ((idx = 0; idx < candidate_count; idx++)); do
  id="${candidate_ids[idx]}"

  if [[ -f "${trees_dir}/${idx}.failed" ]] || [[ -f "${trees_dir}/${idx}.empty" ]]; then
    if [[ -f "${trees_dir}/${idx}.failed" ]]; then
      echo "::warning::Failed to fetch repository tree for ${id}. Marking as skipped."
    fi
    jq -cn --arg id "${id}" '$id' >>"${skipped_file}"
    continue
  fi

  if [[ ! -f "${trees_dir}/${idx}.tree" ]]; then
    jq -cn --arg id "${id}" '$id' >>"${skipped_file}"
    continue
  fi

  full_tree=$(cat "${trees_dir}/${idx}.tree")

  # Check for _quarto.yml/_quarto.yaml (project), excluding _extensions/
  project_files=$(echo "${full_tree}" | grep -E '(^|/)_quarto\.ya?ml$' | grep -vE '(^|/)_extensions/' || true)

  if [[ -n "${project_files}" ]]; then
    best_path=$(echo "${project_files}" | find_best_project_path)
    if [[ -n "${best_path}" ]]; then
      jq -cn --arg id "${id}" --arg pp "${best_path}" \
        '{id: $id, type: "project", project_path: $pp}' >>"${phase_b_entries_file}"
      continue
    fi
  fi

  # Fallback: check for standalone .qmd files (document)
  qmd_files=$(echo "${full_tree}" | grep -E '\.qmd$' || true)

  if [[ -n "${qmd_files}" ]]; then
    doc_files=$(echo "${qmd_files}" | jq -Rsc '
      split("\n")[:-1]
      | map(select(test("(^|/)(_extensions|tests|examples)/") | not))
    ')
    if [[ "$(echo "${doc_files}" | jq 'length')" -gt 0 ]]; then
      jq -cn --arg id "${id}" --argjson files "${doc_files}" \
        '{id: $id, type: "document", qmd_files: $files}' >>"${phase_b_entries_file}"
      continue
    fi
  fi

  jq -cn --arg id "${id}" '$id' >>"${skipped_file}"
done

phase_b_entries='[]'
if [[ -s "${phase_b_entries_file}" ]]; then
  phase_b_entries=$(jq -sc '.' "${phase_b_entries_file}")
fi
skipped='[]'
if [[ -s "${skipped_file}" ]]; then
  skipped=$(jq -sc '.' "${skipped_file}")
fi
entries=$(jq -nc --argjson a "${entries_phase_a}" --argjson b "${phase_b_entries}" '$a + $b')

image_meta_map=$(jq -nc '{}')
for channel in release prerelease; do
  image_tag="ghcr.io/mcanouil/quarto-extensions:${channel}"

  if ! retry 3 5 docker pull "${image_tag}" >/dev/null 2>&1; then
    echo "::error::Failed to pull image '${image_tag}'."
    exit 1
  fi
  image_ref=$(docker image inspect --format='{{index .RepoDigests 0}}' "${image_tag}" 2>/dev/null || true)
  if [[ -z "${image_ref}" ]]; then
    echo "::error::Failed to resolve digest for image '${image_tag}'."
    exit 1
  fi
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::Resolved image reference '${image_ref}' is not a valid digest-pinned reference."
    exit 1
  fi
  if docker run --rm --user root \
    --cap-drop=ALL --read-only --network=none \
    "${image_ref}" bash -lc '
    set -euo pipefail
    dpkg -s \
      jq \
      libcurl4-openssl-dev \
      libssl-dev \
      libxml2-dev \
      libfontconfig1-dev \
      libharfbuzz-dev \
      libfribidi-dev \
      libfreetype6-dev \
      libpng-dev \
      libtiff5-dev \
      libjpeg-dev \
      libgit2-dev \
      zlib1g-dev \
      cmake >/dev/null 2>&1
  '; then
    is_ready=true
  else
    is_ready=false
  fi
  image_meta_map=$(echo "${image_meta_map}" | jq \
    --arg ch "${channel}" \
    --arg ref "${image_ref}" \
    --argjson ready "${is_ready}" \
    '. + {($ch): {image_ref: $ref, image_ready: $ready}}')
done

if ! echo "${image_meta_map}" | jq -e '
  (.release.image_ref | type == "string")
  and (.prerelease.image_ref | type == "string")
  and (.release.image_ready | type == "boolean")
  and (.prerelease.image_ready | type == "boolean")
' >/dev/null 2>&1; then
  echo "::error::Image metadata is incomplete."
  exit 1
fi

# In debug mode, take up to 5 per type for a representative sample
if [[ "${DEBUG}" == "true" ]]; then
  entries=$(echo "${entries}" | jq '
    [sort_by(.type) | group_by(.type)[] | .[0:5]] | flatten
  ')
fi

total=$(echo "${entries}" | jq 'length')
echo "Total extensions to test: ${total}"

matrix=$(echo "${entries}" | jq -c --argjson n "${BATCH_SIZE}" --argjson meta "${image_meta_map}" '
  def pad3: tostring | if length < 3 then ("000" + .)[-3:] else . end;
  . as $all
  | if ($all | length) == 0 then
      {
        include: [
          {
            batch_index: (0 | pad3),
            quarto_channel: "release",
            image_ref: $meta.release.image_ref,
            image_ready: $meta.release.image_ready,
            extensions: []
          },
          {
            batch_index: (0 | pad3),
            quarto_channel: "prerelease",
            image_ref: $meta.prerelease.image_ref,
            image_ready: $meta.prerelease.image_ready,
            extensions: []
          }
        ]
      }
    else
      [range(0; ($all | length); $n)] as $starts
      | {
          include: (
            $starts
            | to_entries
            | map(
                .value as $s
                | .key as $bi
                  | [
                    {
                      batch_index: ($bi | pad3),
                      quarto_channel: "release",
                      image_ref: $meta.release.image_ref,
                      image_ready: $meta.release.image_ready,
                      extensions: $all[$s:($s + $n)]
                    },
                    {
                      batch_index: ($bi | pad3),
                      quarto_channel: "prerelease",
                      image_ref: $meta.prerelease.image_ref,
                      image_ready: $meta.prerelease.image_ready,
                      extensions: $all[$s:($s + $n)]
                    }
                  ]
              )
            | add
          )
        }
    end
')

job_count=$(echo "${matrix}" | jq '.include | length')
echo "Matrix jobs: ${job_count}"

echo "matrix=$(echo "${matrix}" | jq -c '.')" >>"${GITHUB_OUTPUT}"
echo "skipped=$(echo "${skipped}" | jq -c '.')" >>"${GITHUB_OUTPUT}"
