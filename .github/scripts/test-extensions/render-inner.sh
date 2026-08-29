#!/usr/bin/env bash
set -euo pipefail

# Render an extension inside the render container.
# Executed via stdin by render-extensions.sh (docker run ... bash < render-inner.sh).
# Inputs (env): EXT_TYPE, EXT_ID, WORKDIR, LOG_DIR
# Inputs (cwd): render_dir contents; ${WORKDIR}/ext-meta.json

# Activate local venv if created during dependency install.
# Preserve access to the image-level venv site-packages so pre-installed
# packages (jupyter, shinylive, pyyaml, etc.) remain importable. The share is
# a .pth file rather than PYTHONPATH: site.py appends the paths it reads from
# a .pth file after the local site-packages, so the versions the repository
# locked keep priority and the image venv only fills genuine gaps. It is also
# limited to an image venv built on the same Python minor version: compiled
# extension modules carry an interpreter-specific suffix, so sharing across
# versions hides the local copy behind one the interpreter cannot import.
IMAGE_VENV="${IMAGE_VENV:-/home/vscode/.venv}"
if [[ -f .venv/bin/activate ]]; then
	# shellcheck disable=SC1091 # created at runtime by uv venv
	source .venv/bin/activate
	if ! read -r venv_tag venv_sitedir < <(
		python3 -c 'import site, sys; print("python%d.%d" % sys.version_info[:2], site.getsitepackages()[0])'
	); then
		echo "Could not inspect the project venv Python for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
		exit 1
	fi
	image_sp="${IMAGE_VENV}/lib/${venv_tag}/site-packages"
	if [[ -d "${image_sp}" ]]; then
		printf '%s\n' "${image_sp}" >"${venv_sitedir}/zz-image-venv.pth"
	else
		image_tags=""
		for lib in "${IMAGE_VENV}"/lib/python*/; do
			[[ -d "${lib}" ]] || continue
			image_tags="${image_tags:+${image_tags}, }$(basename "${lib}")"
		done
		# Also on the job log: this decides which packages the render can
		# import, so it must be readable without opening the extension log.
		mismatch="Image venv (${image_tags:-none}) does not match the project venv (${venv_tag}) for ${EXT_ID}; its packages are not shared."
		echo "${mismatch}"
		echo "${mismatch}" >>"${LOG_DIR}/stdout.log"
	fi
fi

# reticulate: prefer its own uv-managed ephemeral environment over the image
# venv (VIRTUAL_ENV, discovery step 5) so Python packages declared via
# py_require() are installed and used to execute the Python cells.
export RETICULATE_USE_MANAGED_VENV=yes

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
# and a pre-created symlink would collide with that copy. docs/ is skipped
# because a documentation website there is never rendered as part of a
# repository that has other content; see the discovery below.
root_ext="$(pwd)/_extensions"
if [[ -d "${root_ext}" ]]; then
	while IFS= read -r -d '' qy; do
		proj_dir="$(dirname "${qy}")"
		[[ "${proj_dir}" == "." ]] && continue
		[[ -e "${proj_dir}/_extensions" ]] && continue
		grep -q '_extensions' "${qy}" && continue
		ln -s "${root_ext}" "${proj_dir}/_extensions"
	done < <(find . \( -name _quarto.yml -o -name _quarto.yaml \) -not -path './_extensions/*' -not -path './docs/*' -print0)
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
	# A documentation website under docs/ is a separate project that documents
	# the extension rather than exercising it, and it often stages the extension
	# with a script the harness knows nothing about, so rendering it reports a
	# failure the extension does not have. Keep it out of the discovery, unless
	# the repository holds nothing else: rendering the site is still better than
	# rendering nothing, which the loop below would report as a pass.
	mapfile -d '' qmd_found < <(find . -name '*.qmd' -not -path './_extensions/*' -not -path './docs/*' -print0)
	if [[ "${#qmd_found[@]}" -eq 0 ]]; then
		mapfile -d '' qmd_found < <(find . -name '*.qmd' -not -path './_extensions/*' -print0)
	fi
	for qmd in "${qmd_found[@]}"; do
		render_single_qmd "${qmd}"
	done
fi
