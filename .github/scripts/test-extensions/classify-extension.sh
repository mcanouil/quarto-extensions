#!/usr/bin/env bash
# Shared classification of a repository tree into a renderable entry.
# Source this file; do not execute it directly.
# Used by build-matrix.sh (monthly tests) and preflight-render.sh (PR checks).

# Pick the best _quarto.yml project path from a list of project file paths
# on stdin: prefer repo root, then docs/, then the shallowest path outside
# tests/ and examples/. Prints nothing when no suitable path exists.
# docs/ stays a candidate here, unlike in the document fallback below: a
# repository whose only project is its documentation website has nothing else
# to render, and rendering the site keeps it under test.
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
		# A documentation website under docs/ documents the extension rather than
		# exercising it, so it is left out. A repository that holds nothing else
		# keeps its docs/ pages, so it stays under test rather than being dropped.
		doc_files=$(printf '%s\n' "${qmd_files}" | jq -Rsc --arg pfx "${prefix}" '
			(split("\n")[:-1] | map(select(test("(^|/)(_extensions|tests|examples)/") | not))) as $all
			| ($all | map(select(test("(^|/)docs/") | not))) as $outside_docs
			| (if ($outside_docs | length) > 0 then $outside_docs else $all end)
			| map(if $pfx != "" then "\($pfx)/\(.)" else . end)
		')
		if [[ "$(echo "${doc_files}" | jq 'length')" -gt 0 ]]; then
			jq -cn --argjson files "${doc_files}" '{type: "document", qmd_files: $files}'
			return 0
		fi
	fi

	return 1
}

# Decide which test mode an entry runs in, from a repository tree on stdin.
# Prints one of: suite, schema, conformance, render-only.
#
# Paths only, because build-matrix.sh works from the trees API and has no file
# contents. A schema this cannot tell is v1 is handled at run time: the
# framework skips it, the run is all skips, and the caller falls back to the
# render it would have done anyway.
detect_test_mode() {
	local tree
	tree=$(cat)

	# The repository's own extension, not an installed copy under docs/ or a
	# staged one under tests/. This mirrors what the framework itself
	# discovers.
	local manifest
	manifest=$(printf '%s\n' "${tree}" | grep -E '^_extensions/[^/]+/_extension\.ya?ml$' || true)
	if [[ -z "${manifest}" ]]; then
		echo "render-only"
		return 0
	fi

	local tests_project tests_documents
	tests_project=$(printf '%s\n' "${tree}" | grep -E '^tests/_quarto\.ya?ml$' || true)
	# A generated, staged or result document is not an authored test.
	tests_documents=$(printf '%s\n' "${tree}" |
		grep -E '^tests/.*\.qmd$' |
		grep -vE '^tests/(_extensions|generated|_results|_output)/' || true)
	if [[ -n "${tests_project}" ]] && [[ -n "${tests_documents}" ]]; then
		echo "suite"
		return 0
	fi

	local schema
	schema=$(printf '%s\n' "${tree}" | grep -E '^_extensions/[^/]+/_schema\.(json|ya?ml)$' || true)
	if [[ -n "${schema}" ]]; then
		echo "schema"
		return 0
	fi

	echo "conformance"
}

# Stamp the default test mode onto a JSON array of entries on stdin, printing
# the array back out. A template or example entry is never classified, so its
# mode is stamped here rather than inherited from whatever a previous entry
# carried; kept separate from build-matrix.sh so the stamping itself can be
# tested. Does not overwrite a test_mode an entry already carries.
stamp_default_test_mode() {
	jq -c 'map(. + {test_mode: (.test_mode // "render-only")})'
}
