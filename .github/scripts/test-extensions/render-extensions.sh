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
	local run_timeout="$1" workdir="$2" log_dir="$3" render_dir="$4" shard="$5" mount_cache="$6"
	shift 6
	local cache_mount=()
	# The shared cache is a read-write surface across repositories within this
	# job, so only a caller that actually needs packages mounts it.
	if [[ "${mount_cache}" == "yes" ]]; then
		cache_mount=(-v "${cache_root}:/cache")
	fi
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
		"${cache_mount[@]}" \
		-v "${workdir}:${workdir}" \
		-v "${log_dir}:${log_dir}" \
		-w "${render_dir}" \
		render-image \
		bash
}

readonly FRAMEWORK_DIR="${GITHUB_WORKSPACE}/extension-test"
readonly FRAMEWORK_RUNNER="${FRAMEWORK_DIR}/_extensions/extension-test/run.lua"
# A catalogue sweep must finish, and a generated document per shortcode per
# format grows with the extension rather than with the catalogue.
readonly FRAMEWORK_MAX_GENERATED=40
readonly FRAMEWORK_TIMEOUT=600

# Run the pinned framework against one clone, writing its JSON into the log
# directory so it travels with the logs the entry already publishes.
#
# `suite` renders the repository's own documents and so keeps the dependency
# cache. `schema` and `conformance` render only documents the framework
# generates, which are markdown with shortcode invocations and no executable
# cells, so they need no packages and mount no cache: that keeps them out of
# the one surface shared between repositories.
run_framework() {
	local mode="$1" workdir="$2" log_dir="$3" render_dir="$4" shard="$5" pre_status="$6"
	local tests_dir layers mount_cache

	case "${mode}" in
	suite)
		tests_dir="${render_dir}/tests"
		layers=(--layer conformance --layer render --layer smoke)
		mount_cache="yes"
		;;
	schema)
		# The catalogue supplies the project, so the repository's own
		# tests/_quarto.yml is never read and none of its render scripts run.
		tests_dir="${workdir}/framework-tests"
		install -d -m 700 "${tests_dir}"
		printf 'project:\n  type: default\n  output-dir: _output\n' >"${tests_dir}/_quarto.yml"
		layers=(--layer conformance --layer smoke)
		mount_cache="no"
		;;
	conformance)
		tests_dir="${workdir}/framework-tests"
		install -d -m 700 "${tests_dir}"
		printf 'project:\n  type: default\n  output-dir: _output\n' >"${tests_dir}/_quarto.yml"
		layers=(--layer conformance)
		mount_cache="no"
		;;
	*)
		return 0
		;;
	esac

	# A repository that has already failed the dependency source policy or a
	# dependency install has not earned write access to a cache shared with
	# every other repository in this job. This costs nothing real: override_
	# applies already refuses a non-pass pre-status, so this run's verdict was
	# never going to be used anyway.
	if [[ "${pre_status}" != "pass" ]]; then
		mount_cache="no"
	fi

	docker_run_render "${FRAMEWORK_TIMEOUT}" "${workdir}" "${log_dir}" "${render_dir}" "${shard}" "${mount_cache}" \
		-v "${FRAMEWORK_DIR}:${FRAMEWORK_DIR}:ro" \
		<<-EOF || true
			set -uo pipefail
			quarto pandoc lua "${FRAMEWORK_RUNNER}" \
				--root "${render_dir}" \
				--tests "${tests_dir}" \
				--json "${log_dir}/extension-test.json" \
				--tap /dev/null \
				--quiet \
				--max-generated ${FRAMEWORK_MAX_GENERATED} \
				${layers[*]}
		EOF
}

# Read the framework's own verdict out of its JSON.
#
# The exit code is not consulted on purpose: an all-skip run exits 0 and is
# otherwise indistinguishable from a clean one, and this is the difference the
# caller needs in order to decide whether to fall back to the render.
#
# `rendered` counts the cases the rendering layers actually decided, which is
# not the same as the run passing. An extension contributing only a project
# type passes conformance and skips its one smoke case, because generate.lua
# names a contributed project type as a gap rather than half-generating it. It
# would otherwise be recorded as a pass having rendered nothing.
#
# Prints: status<TAB>total<TAB>pass<TAB>fail<TAB>skip<TAB>rendered, where
# status is `none` when there is nothing readable.
framework_verdict() {
	local json="$1"
	if [[ ! -s "${json}" ]]; then
		printf 'none\t0\t0\t0\t0\t0\n'
		return 0
	fi
	# Only a bounded enum and four integers may reach the published catalogue.
	# The JSON is written inside the container by the repository's own
	# extension, so `numbers` coerces anything a repository puts there other
	# than a number (a string, a boolean, an array) down to the default,
	# rather than letting it travel through @tsv and later --argjson.
	jq -r '
		[(.status // "none"),
		 (.summary.total | numbers // 0), (.summary.pass | numbers // 0),
		 (.summary.fail | numbers // 0), (.summary.skip | numbers // 0),
		 ([(.layers.render // {}), (.layers.smoke // {})]
		  | map((.pass | numbers // 0) + (.fail | numbers // 0)) | add)]
		| @tsv
	' "${json}" 2>/dev/null || printf 'none\t0\t0\t0\t0\t0\n'
}

# Whether the framework's verdict replaces the render's.
#
# Replacing the render must never mean checking less, so three things must all
# hold: the mode is one where the framework renders, it reached a verdict, and
# it actually decided at least one rendering case. The third is not implied by
# the second. An extension contributing only a project type passes conformance
# and skips its only smoke case, so the run reports pass while having rendered
# nothing; taking that verdict would mark the entry green and drop the render
# it gets today.
framework_decides() {
	local mode="$1" verdict="$2" fail_count="$3" rendered="$4"
	case "${mode}" in
	suite | schema) ;;
	*)
		echo "no"
		return 0
		;;
	esac
	if [[ "${rendered}" -lt 1 ]]; then
		echo "no"
		return 0
	fi
	if [[ "${verdict}" == "pass" ]] || { [[ "${verdict}" == "fail" ]] && [[ "${fail_count}" -gt 0 ]]; }; then
		echo "yes"
	else
		echo "no"
	fi
}

# Whether the framework's verdict overrides the render's status.
#
# The framework may add a failure the render missed, but must never erase one
# the render already found: a clone, policy, dependency or render failure is a
# fact about the entry that a later, decoupled probe cannot disprove. So the
# override only ever applies when the render itself was clean going in.
override_applies() {
	local pre_status="$1" mode="$2" verdict="$3" fail_count="$4" rendered="$5"
	if [[ "${pre_status}" != "pass" ]]; then
		echo "no"
		return 0
	fi
	framework_decides "${mode}" "${verdict}" "${fail_count}" "${rendered}"
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
				docker_run_render 600 "${workdir}" "${log_dir}" "${render_dir}" "${shard}" yes \
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
			render_rc=0
			docker_run_render 300 "${workdir}" "${log_dir}" "${render_dir}" "${shard}" yes \
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

	local pre_framework_status="${status}"
	local test_mode fw_status fw_total fw_pass fw_fail fw_skip fw_rendered
	test_mode=$(jq -r ".[${i}].ext.test_mode // \"render-only\"" clone-manifest.json)

	fw_status="none"
	fw_total=0
	fw_pass=0
	fw_fail=0
	fw_skip=0
	fw_rendered=0
	if [[ "${test_mode}" != "render-only" ]] && [[ "${status}" != "skip" ]]; then
		run_framework "${test_mode}" "${workdir}" "${log_dir}" "${render_dir}" "${shard}" "${pre_framework_status}"
		# The fallback branches of framework_verdict always emit a trailing
		# newline, but `|| true` keeps this shard alive even if a future change
		# to that contract lets a delimiter-less read hit EOF again.
		IFS=$'\t' read -r fw_status fw_total fw_pass fw_fail fw_skip fw_rendered < <(
			framework_verdict "${log_dir}/extension-test.json"
		) || true
	fi

	if [[ "$(override_applies "${pre_framework_status}" "${test_mode}" "${fw_status}" "${fw_fail}" "${fw_rendered}")" == "yes" ]]; then
		if [[ "${fw_status}" == "fail" ]]; then
			status="fail"
			stage="extension-test"
			# Bounded on purpose: the detail is repository-derived text and
			# stays in the log rather than entering the published catalogue.
			failure_reason="cases-failed"
		else
			status="pass"
			stage=""
			failure_reason=""
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
		--arg test_mode "${test_mode}" \
		--argjson cases "$(jq -cn \
			--argjson total "${fw_total}" --argjson pass "${fw_pass}" \
			--argjson fail "${fw_fail}" --argjson skip "${fw_skip}" \
			'{total: $total, pass: $pass, fail: $fail, skip: $skip}')" \
		'{id: $id, type: $t, status: $s, log: $l, quarto_version: $qv, quarto_channel: $qc, stage: $st, failure_reason: $fr, test_mode: $test_mode, cases: $cases}' \
		>"${results_dir}/${i}.json"
}

# Static interleaved sharding: shard w renders indices i where
# i % RENDER_CONCURRENCY == w. Results are per-index files because subshell
# variable updates do not propagate to the parent.
render_shard() {
	local shard="$1"
	local i
	for ((i = shard; i < ext_count; i += RENDER_CONCURRENCY)); do
		render_extension "${i}" "${shard}"
	done
}

shard_pids=()
for ((w = 0; w < RENDER_CONCURRENCY; w++)); do
	render_shard "${w}" &
	shard_pids+=("$!")
done
for ((w = 0; w < RENDER_CONCURRENCY; w++)); do
	if ! wait "${shard_pids[w]}"; then
		echo "::warning::Render shard ${w} exited non-zero; its remaining extensions were not rendered."
	fi
done

shopt -s nullglob
result_files=("${results_dir}"/*.json)
shopt -u nullglob
if ((${#result_files[@]} > 0)); then
	jq -sc '.' "${result_files[@]}" >results.json
else
	echo '[]' >results.json
fi
# Count entries for which a render was executed: a pass, a failure at the
# render stage, or a failure at the extension-test stage (earlier stages
# never reach quarto render; an extension-test failure means the framework
# decided the entry after render_extension had already run the render).
count_renders() {
	jq '[.[] | select(.status == "pass" or .stage == "render" or .stage == "extension-test")] | length' "$1"
}

render_count=$(count_renders results.json)

if [[ "${ext_count}" -gt 0 ]] && [[ "${render_count}" -eq 0 ]]; then
	echo "::error::No quarto render was executed for ${ext_count} extensions."
	exit 1
fi

echo "Rendered ${render_count}/${ext_count} extensions."
echo "Shared cache size: $(du -sh "${cache_root}" 2>/dev/null | cut -f1)"
df -h /
echo "Results:"
jq '.' results.json
