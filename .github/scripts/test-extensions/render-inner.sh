#!/usr/bin/env bash
set -euo pipefail

# Render an extension inside the render container.
# Executed via stdin by render-extensions.sh (docker run ... bash < render-inner.sh).
# Inputs (env): EXT_TYPE, EXT_ID, WORKDIR, LOG_DIR
# Inputs (cwd): render_dir contents; ${WORKDIR}/ext-meta.json

# Activate local venv if created during dependency install.
# Preserve access to the image-level venv site-packages so pre-installed
# packages (jupyter, shinylive, pyyaml, etc.) remain importable.
IMAGE_VENV="/home/vscode/.venv"
if [[ -f .venv/bin/activate ]]; then
	image_sp=""
	for sp in "${IMAGE_VENV}"/lib/python*/site-packages; do
		if [[ -d "${sp}" ]]; then
			image_sp="${sp}"
			break
		fi
	done
	# shellcheck disable=SC1091 # created at runtime by uv venv
	source .venv/bin/activate
	if [[ -n "${image_sp}" ]]; then
		export PYTHONPATH="${PYTHONPATH:+${PYTHONPATH}:}${image_sp}"
	fi
fi

quarto_render() {
	local log_name="$1"
	shift
	if ! quarto render "$@" --log "${WORKDIR}/${log_name}.log" --log-level info \
		>>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log"; then
		echo "Render failed, retrying once..." >>"${LOG_DIR}/stderr.log"
		quarto render "$@" --log "${WORKDIR}/${log_name}.log" --log-level info \
			>>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || return 1
	fi
}

render_single_qmd() {
	local qmd="$1"
	local base
	base="$(basename "${qmd}" .qmd)"
	local formats
	formats=$(quarto inspect "${qmd}" 2>/dev/null | jq -r '.formats | keys[]' 2>/dev/null) || formats=""
	if [[ -z "${formats}" ]]; then
		quarto_render "${base}" "${qmd}" || exit 1
	else
		while IFS= read -r fmt; do
			quarto_render "${base}-${fmt}" "${qmd}" --to "${fmt}" || exit 1
		done <<<"${formats}"
	fi
}

# Extension dev repos keep _extensions at the repo root and symlink it into
# example/test subprojects, where the link is typically gitignored. Recreate
# those links so nested _quarto.yml projects resolve the extension when their
# documents are rendered individually. Skip projects whose _quarto.yml already
# references _extensions: they manage it themselves (e.g. a pre-render copy),
# and a pre-created symlink would collide with that copy.
root_ext="$(pwd)/_extensions"
if [[ -d "${root_ext}" ]]; then
	while IFS= read -r -d '' qy; do
		proj_dir="$(dirname "${qy}")"
		[[ "${proj_dir}" == "." ]] && continue
		[[ -e "${proj_dir}/_extensions" ]] && continue
		grep -q '_extensions' "${qy}" && continue
		ln -s "${root_ext}" "${proj_dir}/_extensions"
	done < <(find . \( -name _quarto.yml -o -name _quarto.yaml \) -not -path './_extensions/*' -print0)
fi

if [[ -f _quarto.yml ]] || [[ -f _quarto.yaml ]]; then
	quarto_render "project" || exit 1
elif [[ "${EXT_TYPE}" == "document" ]]; then
	qmd_files=$(jq -r '.qmd_files[]?' "${WORKDIR}/ext-meta.json")
	while IFS= read -r qmd; do
		if [[ "${qmd}" == /* ]] || [[ "${qmd}" == *".."* ]]; then continue; fi
		if [[ -f "${qmd}" ]]; then
			render_single_qmd "${qmd}"
		fi
	done <<<"${qmd_files}"
else
	while IFS= read -r -d '' qmd; do
		render_single_qmd "${qmd}"
	done < <(find . -name '*.qmd' -not -path './_extensions/*' -print0)
fi
