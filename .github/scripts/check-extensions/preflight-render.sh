#!/usr/bin/env bash
set -euo pipefail

# Pre-flight render of extensions added in a submission PR.
# Reuses the test-extensions harness; results are reported via step outputs
# (picked up by the summary job and sticky PR comment) and are never
# committed anywhere. Logs are uploaded as workflow artefacts only.
# Inputs (env): DIFF (base64-encoded added CSV lines), CSV_FILE, IMAGE,
#               GITHUB_WORKSPACE, GITHUB_OUTPUT, GITHUB_TOKEN
# Inputs (env, optional): QUARTO_CHANNEL (default release),
#               MAX_PREFLIGHT_ENTRIES (default 5), BLOCKING (default false)
# Outputs (GITHUB_OUTPUT): errors (blocking failures), notes (passes, skips,
#               and advisory failures) — JSON arrays of {line, message}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPTS_DIR="${SCRIPT_DIR}/../test-extensions"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../test-extensions/classify-extension.sh
source "${TEST_SCRIPTS_DIR}/classify-extension.sh"

IMAGE="${IMAGE:?IMAGE is required (e.g. ghcr.io/<owner>/<repo>:release)}"
QUARTO_CHANNEL="${QUARTO_CHANNEL:-release}"
MAX_PREFLIGHT_ENTRIES="${MAX_PREFLIGHT_ENTRIES:-5}"
BLOCKING="${BLOCKING:-false}"

mapfile -t entries < <(read_diff_entries)

if ((${#entries[@]} == 0)); then
	write_check_outputs
	exit 0
fi

if ((${#entries[@]} > MAX_PREFLIGHT_ENTRIES)); then
	echo "::notice::${#entries[@]} entries added; pre-flight render is limited to ${MAX_PREFLIGHT_ENTRIES}. Skipping."
	add_note "${entries[0]}" "Pre-flight render skipped: ${#entries[@]} entries added (limit ${MAX_PREFLIGHT_ENTRIES})."
	write_check_outputs
	exit 0
fi

# Classify each valid entry into a renderable batch entry.
batch_file=$(mktemp)
trap 'rm -f "${batch_file}"' EXIT
declare -A batch_entry_for_repo

for entry in "${entries[@]}"; do
	if [[ ! "${entry}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?$ ]] || [[ "${entry}" == *".."* ]]; then
		add_note "${entry}" "Pre-flight render skipped: entry format not recognised."
		continue
	fi
	repo=$(entry_repo "${entry}")
	subdir=$(entry_subdir "${entry}")

	# One render per repository: a second entry for the same repo (different
	# subdir) would clash with the first in the id-keyed results.
	if [[ -n "${batch_entry_for_repo[${repo}]:-}" ]]; then
		add_note "${entry}" "Pre-flight render skipped: repository already rendered for entry \`${batch_entry_for_repo[${repo}]}\` in this pull request."
		continue
	fi

	tree=$(fetch_repo_tree "${repo}")
	if [[ -z "${tree}" ]]; then
		add_note "${entry}" "Pre-flight render skipped: could not retrieve the repository file tree."
		continue
	fi

	if entry_json=$(printf '%s\n' "${tree}" | classify_extension_tree "${subdir}"); then
		jq -cn --arg id "${repo}" --argjson e "${entry_json}" '{id: $id} + $e' >>"${batch_file}"
		batch_entry_for_repo["${repo}"]="${entry}"
	else
		add_note "${entry}" "Pre-flight render skipped: no renderable content found (no \`_quarto.yml\` project or standalone \`.qmd\` files)."
	fi
done

if [[ ! -s "${batch_file}" ]]; then
	write_check_outputs
	exit 0
fi
jq -sc '.' "${batch_file}" >extensions-batch.json
echo "Pre-flight batch:"
jq '.' extensions-batch.json

# Render via the shared harness (hardened containers, no publication).
# The render harness exits non-zero when no render was executed at all
# (e.g. every entry failed at clone or dependency install); results.json is
# still written, so keep going and report per-entry outcomes.
IMAGE="${IMAGE}" bash "${TEST_SCRIPTS_DIR}/prepare-image.sh"
QUARTO_CHANNEL="${QUARTO_CHANNEL}" bash "${TEST_SCRIPTS_DIR}/clone-extensions.sh"
QUARTO_CHANNEL="${QUARTO_CHANNEL}" RENDER_CONCURRENCY=2 bash "${TEST_SCRIPTS_DIR}/render-extensions.sh" ||
	echo "::warning::Render harness exited non-zero; reporting per-entry results."

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
failed=0

while IFS=$'\t' read -r id status stage failure_reason quarto_version log_path; do
	entry="${batch_entry_for_repo[${id}]:-${id}}"

	case "${status}" in
	pass)
		add_note "${entry}" "Pre-flight render passed with Quarto ${quarto_version} (${QUARTO_CHANNEL})."
		;;
	skip)
		add_note "${entry}" "Pre-flight render skipped: repository is not publicly accessible."
		;;
	*)
		failed=$((failed + 1))
		log_tail=""
		if [[ -f "${log_path}/stderr.log" ]]; then
			log_tail=$(tail -c 4096 "${log_path}/stderr.log" | tail -n 20 | head -c 1500)
			# Backtick fences in the log would break the fenced block in the PR comment.
			log_tail="${log_tail//\`\`\`/~~~}"
		fi
		message="Pre-flight render failed with Quarto ${quarto_version} (${QUARTO_CHANNEL}) at stage \`${stage:-unknown}\`${failure_reason:+ (${failure_reason})}."
		if [[ -n "${log_tail}" ]]; then
			message+=$'\n\n<details><summary>Log excerpt (stderr)</summary>\n\n```\n'"${log_tail}"$'\n```\n\n</details>'
		fi
		message+=$'\n'"Full logs: \`preflight-render-logs\` artefact on the [workflow run](${run_url})."
		if [[ "${BLOCKING}" == "true" ]]; then
			add_error "${entry}" "${message}"
		else
			add_note "${entry}" "${message} (Advisory: this does not block the submission.)"
		fi
		;;
	esac
done < <(jq -r '.[] | [.id, .status, .stage // "", .failure_reason // "", .quarto_version, .log] | @tsv' results.json)

write_check_outputs

if [[ "${BLOCKING}" == "true" ]] && ((failed > 0)); then
	echo "::error::Pre-flight render failed for ${failed} extension(s)."
	exit 1
fi
if ((failed > 0)); then
	echo "::warning::Pre-flight render failed for ${failed} extension(s) (advisory)."
fi
