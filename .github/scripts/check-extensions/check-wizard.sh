#!/usr/bin/env bash
set -euo pipefail

# Suggest Quarto Wizard support (schema/snippets) for added extensions.
# Advisory only: emits notes, never errors.
# Inputs (env): DIFF, CSV_FILE, GITHUB_OUTPUT, GITHUB_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

while IFS=, read -r entry; do
	repo=$(entry_repo "${entry}")
	subdir=$(entry_subdir "${entry}")

	tree=$(fetch_repo_tree "${repo}")
	if [[ -z "${tree}" ]]; then
		continue
	fi

	ext_prefix="${subdir:+${subdir}/}"

	has_extension=$(echo "${tree}" | grep -E "^${ext_prefix}_extensions/[^/]+/_extension\.yml$" | head -n 1 || true)
	if [[ -z "${has_extension}" ]]; then
		continue
	fi

	ext_dir=$(dirname "${has_extension}")

	has_schema=$(echo "${tree}" | grep -E "^${ext_dir}/_schema\.(yml|yaml|json)$" || true)
	has_snippets=$(echo "${tree}" | grep -E "^${ext_dir}/_snippets\.json$" || true)

	if [[ -z "${has_schema}" && -z "${has_snippets}" ]]; then
		missing="schema (\`_schema.yml\`) and snippets (\`_snippets.json\`) files"
	elif [[ -z "${has_schema}" ]]; then
		missing="schema (\`_schema.yml\`) file"
	elif [[ -z "${has_snippets}" ]]; then
		missing="snippets (\`_snippets.json\`) file"
	else
		continue
	fi

	add_note "${entry}" "Extension is missing ${missing}. Consider adding [Quarto Wizard](https://m.canouil.dev/quarto-wizard/) support to provide autocompletion, validation, hover documentation, and code snippets in editors. See [Schema Specification](https://m.canouil.dev/quarto-wizard/reference/schema-specification.html) and [Snippet Specification](https://m.canouil.dev/quarto-wizard/reference/snippet-specification.html)."
done < <(read_diff_entries)

write_check_outputs
