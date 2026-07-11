#!/usr/bin/env bash
# Shared classification of a repository tree into a renderable entry.
# Source this file; do not execute it directly.
# Used by build-matrix.sh (monthly tests) and preflight-render.sh (PR checks).

# Pick the best _quarto.yml project path from a list of project file paths
# on stdin: prefer repo root, then docs/, then the shallowest path outside
# tests/ and examples/. Prints nothing when no suitable path exists.
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
		depth=$((${#slashes} + 1))
		if [[ "${depth}" -lt "${best_depth}" ]]; then
			best_path="${dir}"
			best_depth="${depth}"
		fi
	done
	if [[ -n "${best_path}" ]]; then
		echo "${best_path}"
	fi
}

# Classify a repository tree (paths on stdin, one per line) into a renderable
# entry. $1 is an optional literal path prefix (CSV subdir) to scope to; the
# emitted project_path/qmd_files stay relative to the repository root.
# Prints {type: "project", project_path} or {type: "document", qmd_files};
# returns 1 when no renderable content is found.
classify_extension_tree() {
	local prefix="${1:-}"
	local tree
	tree=$(cat)

	if [[ -n "${prefix}" ]]; then
		tree=$(printf '%s\n' "${tree}" | awk -v p="${prefix}/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }')
	fi

	# Check for _quarto.yml/_quarto.yaml (project), excluding _extensions/
	local project_files
	project_files=$(printf '%s\n' "${tree}" | grep -E '(^|/)_quarto\.ya?ml$' | grep -vE '(^|/)_extensions/' || true)

	if [[ -n "${project_files}" ]]; then
		local best_path
		best_path=$(printf '%s\n' "${project_files}" | find_best_project_path)
		if [[ -n "${best_path}" ]]; then
			if [[ -n "${prefix}" ]]; then
				if [[ "${best_path}" == "." ]]; then
					best_path="${prefix}"
				else
					best_path="${prefix}/${best_path}"
				fi
			fi
			jq -cn --arg pp "${best_path}" '{type: "project", project_path: $pp}'
			return 0
		fi
	fi

	# Fallback: check for standalone .qmd files (document)
	local qmd_files
	qmd_files=$(printf '%s\n' "${tree}" | grep -E '\.qmd$' || true)

	if [[ -n "${qmd_files}" ]]; then
		local doc_files
		doc_files=$(printf '%s\n' "${qmd_files}" | jq -Rsc --arg pfx "${prefix}" '
			split("\n")[:-1]
			| map(select(test("(^|/)(_extensions|tests|examples)/") | not))
			| map(if $pfx != "" then "\($pfx)/\(.)" else . end)
		')
		if [[ "$(echo "${doc_files}" | jq 'length')" -gt 0 ]]; then
			jq -cn --argjson files "${doc_files}" '{type: "document", qmd_files: $files}'
			return 0
		fi
	fi

	return 1
}
