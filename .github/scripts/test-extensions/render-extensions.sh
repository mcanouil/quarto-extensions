#!/usr/bin/env bash
set -euo pipefail

# Render extensions for the test-extensions workflow.
# Inputs (env): QUARTO_CHANNEL, RENDER_CONCURRENCY (default 2)
# Inputs (files): clone-manifest.json, quarto-version.txt
# Outputs (files): results.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-config.sh
source "${SCRIPT_DIR}/docker-config.sh"

RENDER_CONCURRENCY="${RENDER_CONCURRENCY:-2}"
if [[ ! "${RENDER_CONCURRENCY}" =~ ^[1-9][0-9]*$ ]]; then
	echo "::error::Invalid RENDER_CONCURRENCY value '${RENDER_CONCURRENCY}'. Expected a positive integer."
	exit 1
fi

results_dir=$(mktemp -d)
trap 'rm -rf "${results_dir}"' EXIT
quarto_version=$(cat quarto-version.txt)
echo "Quarto version: ${quarto_version} (${QUARTO_CHANNEL})"

ext_count=$(jq 'length' clone-manifest.json)

# Package caches shared across extensions within this job only (never
# persisted across jobs or runs, so cache poisoning is bounded to one batch).
# The R library is per shard: concurrent install.packages into one library
# is racy; renv, uv, and Julia caches are concurrency-safe.
cache_root="${GITHUB_WORKSPACE}/cache"
install -d -m 700 "${cache_root}/renv" "${cache_root}/uv" "${cache_root}/julia"
for ((w = 0; w < RENDER_CONCURRENCY; w++)); do
	install -d -m 700 "${cache_root}/r-lib-${w}"
done

docker_run_render() {
	local run_timeout="$1" workdir="$2" log_dir="$3" render_dir="$4" shard="$5"
	shift 5
	timeout --kill-after=30 "${run_timeout}" docker run --rm -i \
		--user "${DOCKER_USER}" \
		"${DOCKER_SECURITY_OPTS[@]}" \
		"$@" \
		-e NO_COLOR=1 \
		-e RENV_CONFIG_SANDBOX_ENABLED=FALSE \
		-e RENV_CONFIG_PPM_ENABLED=TRUE \
		-e RENV_CONFIG_REPOS_OVERRIDE="https://packagemanager.posit.co/cran/latest" \
		-e QUARTO_CHROMIUM="/usr/bin/google-chrome-stable" \
		-e HOME="${workdir}" \
		-e XDG_CACHE_HOME="${workdir}/.cache" \
		-e TEXMFVAR="/tmp/texmf-var" \
		-e TEXMFCONFIG="/tmp/texmf-config" \
		-e RENV_PATHS_CACHE="/cache/renv" \
		-e UV_CACHE_DIR="/cache/uv" \
		-e JULIA_DEPOT_PATH="/cache/julia:" \
		-e R_LIBS_USER="/cache/r-lib-${shard}" \
		-v "${cache_root}:/cache" \
		-v "${workdir}:${workdir}" \
		-v "${log_dir}:${log_dir}" \
		-w "${render_dir}" \
		render-image \
		bash
}

render_extension() {
	local i="$1"
	local shard="${2:-0}"

	local id ext_type status workdir render_dir log_dir log_path ext
	IFS=$'\t' read -r id ext_type status workdir render_dir log_dir log_path < <(
		jq -r ".[${i}] | [.id // \"\", .type // \"\", .clone_status // \"\", .workdir // \"\", .render_dir // \"\", .log_dir // \"\", .log_path // \"\"] | @tsv" clone-manifest.json
	)
	ext=$(jq -c ".[${i}].ext" clone-manifest.json)

	if [[ -z "${id}" ]] || [[ -z "${ext_type}" ]] || [[ -z "${status}" ]] || [[ -z "${workdir}" ]] || [[ -z "${render_dir}" ]] || [[ -z "${log_dir}" ]] || [[ -z "${log_path}" ]]; then
		echo "::warning::Skipping malformed clone-manifest entry at index ${i}."
		return
	fi

	# Failure-stage taxonomy: clone|policy|deps|render (empty on pass)
	local stage="" failure_reason=""
	if [[ "${status}" == "fail" ]]; then
		stage="clone"
		failure_reason="clone failed"
	elif [[ "${status}" == "skip" ]]; then
		stage="clone"
		failure_reason="repository-inaccessible"
	fi

	if [[ "${status}" == "pass" ]]; then
		printf '%s\n' "${ext}" >"${workdir}/ext-meta.json"

		# Dependency source policy check
		if [[ -f "${render_dir}/renv.lock" ]] || [[ -f "${render_dir}/uv.lock" ]] || [[ -f "${render_dir}/requirements.txt" ]] || [[ -f "${render_dir}/Project.toml" ]] || [[ -f "${render_dir}/JuliaProject.toml" ]]; then
			if ! (cd "${render_dir}" && EXT_ID="${id}" bash "${SCRIPT_DIR}/dependency-policy.sh") \
				>>"${log_dir}/stdout.log" 2>>"${log_dir}/stderr.log"; then
				echo "::warning::Dependency policy check failed for ${id}."
				status="fail"
				stage="policy"
				failure_reason="dependency source policy violation"
			fi
		fi

		# Phase A: Install dependencies (network allowed)
		if [[ "${status}" == "pass" ]]; then
			dep_sources=()
			[[ -f "${render_dir}/renv.lock" ]] && dep_sources+=("renv.lock")
			[[ -f "${render_dir}/uv.lock" ]] && dep_sources+=("uv.lock")
			[[ -f "${render_dir}/requirements.txt" ]] && dep_sources+=("requirements.txt")
			[[ -f "${render_dir}/Project.toml" ]] && dep_sources+=("Project.toml")
			[[ -f "${render_dir}/JuliaProject.toml" ]] && dep_sources+=("JuliaProject.toml")
			if [[ ${#dep_sources[@]} -eq 0 ]]; then
				dep_sources+=("auto-detect")
			fi
			echo "Dependency install phase for ${id}: ${dep_sources[*]}" >>"${log_dir}/stdout.log"
			run_dep_install() {
				docker_run_render 600 "${workdir}" "${log_dir}" "${render_dir}" "${shard}" \
					-e EXT_ID="${id}" \
					-e LOG_DIR="${log_dir}" \
					<"${SCRIPT_DIR}/deps-install.sh"
			}
			dep_rc=0
			run_dep_install || dep_rc=$?
			# Retry once to absorb network flakes; a timeout already ate 600s, do not re-run it.
			if [[ "${dep_rc}" -ne 0 ]] && [[ "${dep_rc}" -ne 124 ]]; then
				echo "Dependency install failed (exit ${dep_rc}) for ${id}; retrying once." >>"${log_dir}/stderr.log"
				dep_rc=0
				run_dep_install || dep_rc=$?
			fi
			if [[ "${dep_rc}" -eq 124 ]]; then
				echo "Dependency install timed out (exit 124) for ${id}." >>"${log_dir}/stderr.log"
				echo "::warning::Dependency install timed out for ${id}."
				status="fail"
				stage="deps"
				failure_reason="timeout"
			elif [[ "${dep_rc}" -ne 0 ]]; then
				echo "Dependency install failed (exit ${dep_rc}) for ${id}." >>"${log_dir}/stderr.log"
				echo "::warning::Dependency install failed (exit ${dep_rc}) for ${id}."
				status="fail"
				stage="deps"
				failure_reason="exit ${dep_rc}"
			fi
		fi

		# Phase B: Render
		if [[ "${status}" == "pass" ]]; then
			touch "${results_dir}/${i}.rendered"
			render_rc=0
			docker_run_render 300 "${workdir}" "${log_dir}" "${render_dir}" "${shard}" \
				-e EXT_TYPE="${ext_type}" \
				-e EXT_ID="${id}" \
				-e WORKDIR="${workdir}" \
				-e LOG_DIR="${log_dir}" \
				<"${SCRIPT_DIR}/render-inner.sh" || render_rc=$?
			if [[ "${render_rc}" -ne 0 ]]; then
				status="fail"
				stage="render"
				if [[ "${render_rc}" -eq 124 ]]; then
					failure_reason="timeout"
				else
					failure_reason="exit ${render_rc}"
				fi
			fi
		fi
	fi

	# Copy render logs to log directory
	find "${workdir}" -maxdepth 1 -name '*.log' -not -name 'stdout.log' -not -name 'stderr.log' -type f -exec cp --no-dereference {} "${log_dir}/" \; 2>/dev/null || true

	if [[ "${status}" == "pass" ]]; then
		echo "Result: ${id} PASSED"
	else
		echo "::warning::Result: ${id} FAILED"
	fi

	# Clean up workdir now that logs are copied
	chmod -R u+w "${workdir}" 2>/dev/null || true
	rm -rf "${workdir}"

	jq -cn \
		--arg id "${id}" \
		--arg t "${ext_type}" \
		--arg s "${status}" \
		--arg l "${log_path}" \
		--arg qv "${quarto_version}" \
		--arg qc "${QUARTO_CHANNEL}" \
		--arg st "${stage}" \
		--arg fr "${failure_reason}" \
		'{id: $id, type: $t, status: $s, log: $l, quarto_version: $qv, quarto_channel: $qc, stage: $st, failure_reason: $fr}' \
		>"${results_dir}/${i}.json"
}

# Static interleaved sharding: shard w renders indices i where
# i % RENDER_CONCURRENCY == w. Results and render markers are per-index
# files because subshell variable updates do not propagate to the parent.
render_shard() {
	local shard="$1"
	local i
	for ((i = shard; i < ext_count; i += RENDER_CONCURRENCY)); do
		render_extension "${i}" "${shard}"
	done
}

for ((w = 0; w < RENDER_CONCURRENCY; w++)); do
	render_shard "${w}" &
done
wait

shopt -s nullglob
result_files=("${results_dir}"/*.json)
if ((${#result_files[@]} > 0)); then
	jq -sc '.' "${result_files[@]}" >results.json
else
	echo '[]' >results.json
fi
render_markers=("${results_dir}"/*.rendered)
render_count=${#render_markers[@]}
shopt -u nullglob

if [[ "${ext_count}" -gt 0 ]] && [[ "${render_count}" -eq 0 ]]; then
	echo "::error::No quarto render was executed for ${ext_count} extensions."
	exit 1
fi

echo "Rendered ${render_count}/${ext_count} extensions."
echo "Shared cache size: $(du -sh "${cache_root}" 2>/dev/null | cut -f1)"
df -h /
echo "Results:"
jq '.' results.json
