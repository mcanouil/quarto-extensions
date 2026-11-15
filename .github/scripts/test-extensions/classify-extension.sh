#!/usr/bin/env bash
# Shared classification of a repository tree into a renderable entry.
# Source this file; do not execute it directly.
# Used by build-matrix.sh (monthly tests) and preflight-render.sh (PR checks).

# Paths that never hold renderable content, and paths inside a documentation
# website. The project ranking, the documents-over-site check and the document
# fallback all read these, so they cannot disagree on what a path is.
CLASSIFY_SKIP_RE='(^|/)(_extensions|tests|examples)(/|$)'
CLASSIFY_DOCS_RE='(^|/)docs(/|$)'

# Pick the best _quarto.yml project path from a list of project file paths
# on stdin: prefer repo root, then the shallowest path outside docs/, tests/
# and examples/, then the shallowest path inside docs/. Prints nothing when no
# suitable path exists. docs/ comes last because a documentation website
# documents the extension rather than exercising it; see
# classify_extension_tree.
find_best_project_path() {
	local best_path="" best_depth=999 docs_path="" docs_depth=999
	while IFS= read -r qpath; do
		local dir
		dir=$(dirname "${qpath}")
		if [[ "${dir}" =~ ${CLASSIFY_SKIP_RE} ]]; then
			continue
		fi
		if [[ "${dir}" == "." ]]; then
			echo "."
			return
		fi
		local depth slashes
		slashes="${dir//[!\/]/}"
		depth=$((${#slashes} + 1))
		if [[ "${dir}" =~ ${CLASSIFY_DOCS_RE} ]]; then
			if [[ "${depth}" -lt "${docs_depth}" ]]; then
				docs_path="${dir}"
				docs_depth="${depth}"
			fi
		elif [[ "${depth}" -lt "${best_depth}" ]]; then
			best_path="${dir}"
			best_depth="${depth}"
		fi
	done
	if [[ -n "${best_path}" ]]; then
		echo "${best_path}"
	elif [[ -n "${docs_path}" ]]; then
		echo "${docs_path}"
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

	local qmd_files
	qmd_files=$(printf '%s\n' "${tree}" | grep -E '\.qmd$' || true)

	# Check for _quarto.yml/_quarto.yaml (project), excluding _extensions/
	local project_files
	project_files=$(printf '%s\n' "${tree}" | grep -E '(^|/)_quarto\.ya?ml$' | grep -vE '(^|/)_extensions/' || true)

	if [[ -n "${project_files}" ]]; then
		local best_path
		best_path=$(printf '%s\n' "${project_files}" | find_best_project_path)
		# A documentation website under docs/ often stages the extension with a
		# script the harness does not run, so a clean clone cannot render it.
		# Documents outside docs/ exercise the extension directly: leave the site
		# to the document fallback below, which picks them instead. A repository
		# that holds nothing else keeps its site, so it stays under test.
		if [[ "${best_path}" =~ ${CLASSIFY_DOCS_RE} ]] &&
			[[ -n "$(printf '%s\n' "${qmd_files}" | grep -vE "${CLASSIFY_SKIP_RE}" | grep -vE "${CLASSIFY_DOCS_RE}" || true)" ]]; then
			best_path=""
		fi
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

	# Fallback: standalone .qmd files (document), docs/ pages only when nothing
	# else is left, for the reason given above.
	if [[ -n "${qmd_files}" ]]; then
		local doc_files
		doc_files=$(printf '%s\n' "${qmd_files}" | jq -Rsc --arg pfx "${prefix}" \
			--arg skip "${CLASSIFY_SKIP_RE}" --arg docs "${CLASSIFY_DOCS_RE}" '
			(split("\n")[:-1] | map(select(test($skip) | not))) as $all
			| ($all | map(select(test($docs) | not))) as $outside_docs
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
# Only build-matrix.sh calls this, so only the monthly sweep runs the
# framework. check-extensions/preflight-render.sh sources this file for
# classify_extension_tree and runs the same render harness, but builds its
# own batch entries without a test_mode, so every one of them defaults to
# render-only: a pull request check gates one new entry, and the sweep is
# where every entry is asserted.
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
