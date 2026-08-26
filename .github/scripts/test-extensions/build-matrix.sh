#!/usr/bin/env bash
set -euo pipefail

# Build the test matrix for the test-extensions workflow.
# Inputs (env): DEBUG, FAILING_ONLY, UNTESTED_ONLY, BATCH_SIZE, GH_TOKEN (for gh api calls)
# Inputs (env, untested-only): MAX_UNTESTED (extensions per run, default 25)
# Inputs (env, debug only): REPO_OWNER (filters to same-owner extensions)
# Inputs (files, failing-only and untested-only): test-results.json (from quarto-tests
#               branch); rewritten in place when missing or malformed
# Outputs (to GITHUB_OUTPUT): matrix, skipped, render_count

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"
# shellcheck source=classify-extension.sh
source "${SCRIPT_DIR}/classify-extension.sh"

if [[ ! "${DEBUG}" =~ ^(true|false)$ ]]; then
  echo "::error::Invalid debug value: '${DEBUG}'. Expected 'true' or 'false'."
  exit 1
fi

FAILING_ONLY="${FAILING_ONLY:-false}"
if [[ ! "${FAILING_ONLY}" =~ ^(true|false)$ ]]; then
  echo "::error::Invalid failing_only value: '${FAILING_ONLY}'. Expected 'true' or 'false'."
  exit 1
fi

UNTESTED_ONLY="${UNTESTED_ONLY:-false}"
if [[ ! "${UNTESTED_ONLY}" =~ ^(true|false)$ ]]; then
  echo "::error::Invalid untested_only value: '${UNTESTED_ONLY}'. Expected 'true' or 'false'."
  exit 1
fi

if [[ ! "${BATCH_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid batch_size value: '${BATCH_SIZE}'. Expected a positive integer."
  exit 1
fi

MAX_UNTESTED="${MAX_UNTESTED:-25}"
if [[ ! "${MAX_UNTESTED}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid max_untested value: '${MAX_UNTESTED}'. Expected a positive integer."
  exit 1
fi

# Both selection modes read the stored results, so normalise the document once.
# A missing or malformed file means nothing has been tested yet.
if [[ "${UNTESTED_ONLY}" == "true" ]] || [[ "${FAILING_ONLY}" == "true" ]]; then
  if [[ ! -f test-results.json ]] || ! jq -e 'type == "object"' test-results.json >/dev/null 2>&1; then
    echo "::warning::Missing or invalid test-results.json. Treating every extension as never tested."
    echo '{}' >test-results.json
  fi
fi

extensions_json=$(cat quarto-extensions.json)
if [[ "${UNTESTED_ONLY}" == "true" ]]; then
  # Filtering here, before the repository trees are fetched, keeps the tree
  # requests to the extensions that need a first result.
  # --slurpfile keeps the stored results off the jq command line, hence $tr[0].
  extensions_json=$(jq -c --slurpfile tr test-results.json '
    with_entries(.key as $id | select($tr[0] | has($id) | not))
  ' <<<"${extensions_json}")
  untested_total=$(jq 'length' <<<"${extensions_json}")
  echo "Untested-only mode: ${untested_total} extension(s) with no stored result."
  # A reset or malformed test-results.json makes every extension untested. The
  # cap keeps that from launching a full run on a path that reuses the images
  # as they stand; the rest are taken by the following runs.
  if [[ "${untested_total}" -gt "${MAX_UNTESTED}" ]]; then
    echo "::warning::Testing ${MAX_UNTESTED} of ${untested_total} untested extensions. The rest are deferred to the next run."
    extensions_json=$(jq -c --argjson n "${MAX_UNTESTED}" '
      to_entries | sort_by(.key) | .[0:$n] | from_entries
    ' <<<"${extensions_json}")
  fi
fi

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

  if entry_json=$(classify_extension_tree "" <"${trees_dir}/${idx}.tree"); then
    jq -cn --arg id "${id}" --argjson e "${entry_json}" '{id: $id} + $e' >>"${phase_b_entries_file}"
    continue
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
  # The publication job reports this list too, but it does not run when nothing
  # is rendered, which is the usual outcome of an untested-only run.
  echo "Skipped (no renderable content found): $(jq -r 'join(", ")' <<<"${skipped}")"
fi
entries=$(jq -nc --argjson a "${entries_phase_a}" --argjson b "${phase_b_entries}" '$a + $b')

image_meta_map=$(jq -nc '{}')
for channel in release prerelease; do
  image_tag="ghcr.io/mcanouil/quarto-extensions:${channel}"

  # Read the digest from the registry manifest. The render jobs pull the image
  # themselves, so downloading it here to inspect it would move gigabytes for
  # a string.
  inspect_error_file=$(mktemp)
  image_digest=$(retry 3 5 docker buildx imagetools inspect "${image_tag}" \
    --format '{{.Manifest.Digest}}' 2>"${inspect_error_file}" || true)
  if [[ -z "${image_digest}" ]]; then
    echo "::error::Failed to resolve digest for image '${image_tag}', which usually means the tag is gone or the image has never been built: $(tr '\n' ' ' <"${inspect_error_file}")"
    rm -f "${inspect_error_file}"
    exit 1
  fi
  rm -f "${inspect_error_file}"
  image_ref="${image_tag%:*}@${image_digest}"
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::Resolved image reference '${image_ref}' is not a valid digest-pinned reference."
    exit 1
  fi
  image_meta_map=$(echo "${image_meta_map}" | jq \
    --arg ch "${channel}" \
    --arg ref "${image_ref}" \
    '. + {($ch): {image_ref: $ref}}')
done

if ! echo "${image_meta_map}" | jq -e '
  (.release.image_ref | type == "string")
  and (.prerelease.image_ref | type == "string")
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

# Map entries to channels. Default: every extension in both channels.
# Failing-only: per channel, keep extensions whose latest tested version failed,
# or that have no stored result for that channel (never tested).
entries_by_channel=$(jq -nc --argjson e "${entries}" '{release: $e, prerelease: $e}')
count=$((total * 2))
# Untested-only leaves nothing for failing-only to select: every survivor has no
# stored result, so the per-channel filter would keep them all and the log line
# would claim a selection that did not happen.
if [[ "${FAILING_ONLY}" == "true" ]] && [[ "${UNTESTED_ONLY}" != "true" ]]; then
  entries_file=$(mktemp)
  printf '%s' "${entries}" >"${entries_file}"
  # Pass large JSON via files (--slurpfile) rather than --argjson so the entry
  # list and test history do not overflow ARG_MAX on the jq command line.
  # --slurpfile wraps each file's content in an array, hence $e[0] and $tr[0].
  entries_by_channel=$(jq -nc --slurpfile e "${entries_file}" --slurpfile tr test-results.json '
    def core(v): (v // "" | split("+")[0] | split("-")[0]
      | split(".") | map((tonumber? // 0)) | . + [0, 0, 0, 0] | .[0:4]);
    def suffix(v): (v // "" | split("+")[0] | split("-")[1:] | join("-"));
    # newer(a; b): version a ranks ahead of b (mirror of compareVersionsDesc < 0).
    def newer(a; b):
      (core(a) as $ca | core(b) as $cb
       | if $ca != $cb then $ca > $cb
         else (suffix(a) as $sa | suffix(b) as $sb
               | if $sa == $sb then false
                 elif $sa == "" then true
                 elif $sb == "" then false
                 else $sa > $sb end) end);
    def selected($results; $id; $ch):
      (($results[$id].results // []) | map(select(.quarto_channel == $ch))) as $cr
      | if ($cr | length) == 0 then true
        else (reduce $cr[] as $r (null;
                if . == null or newer($r.quarto_version; .quarto_version)
                then $r else . end) | .status == "fail")
        end;
    $e[0] as $entries
    | $tr[0] as $results
    | {
        release: [$entries[] | select(selected($results; .id; "release"))],
        prerelease: [$entries[] | select(selected($results; .id; "prerelease"))]
      }
  ')
  rm -f "${entries_file}"
  rel_count=$(echo "${entries_by_channel}" | jq '.release | length')
  pre_count=$(echo "${entries_by_channel}" | jq '.prerelease | length')
  echo "Failing-only selection: release=${rel_count}, prerelease=${pre_count}"
  count=$((rel_count + pre_count))
fi

# Renders to run across both channels. The workflow skips the render and
# publication jobs when this is zero.
echo "Renders to run: ${count}"

matrix=$(echo "${entries_by_channel}" | jq -c --argjson n "${BATCH_SIZE}" --argjson meta "${image_meta_map}" '
  def pad3: tostring | if length < 3 then ("000" + .)[-3:] else . end;
  . as $byc
  | {
      include: (
        ["release", "prerelease"]
        | map(
            . as $ch
            | ($byc[$ch] // []) as $list
            | $meta[$ch].image_ref as $img
            | if ($list | length) == 0 then
                [{batch_index: (0 | pad3), quarto_channel: $ch, image_ref: $img, extensions: []}]
              else
                [range(0; ($list | length); $n)]
                | to_entries
                | map(
                    .value as $s
                    | .key as $bi
                    | {batch_index: ($bi | pad3), quarto_channel: $ch, image_ref: $img, extensions: $list[$s:($s + $n)]}
                  )
              end
          )
        | add
      )
    }
')

job_count=$(echo "${matrix}" | jq '.include | length')
echo "Matrix jobs: ${job_count}"

{
  echo "matrix=${matrix}"
  echo "skipped=${skipped}"
  echo "render_count=${count}"
} >>"${GITHUB_OUTPUT}"
