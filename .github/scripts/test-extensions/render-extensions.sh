#!/usr/bin/env bash
set -euo pipefail

# Render extensions for the test-extensions workflow.
# Inputs (env): QUARTO_CHANNEL
# Inputs (files): clone-manifest.json, quarto-version.txt
# Outputs (files): results.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-config.sh
source "${SCRIPT_DIR}/docker-config.sh"

results_file=$(mktemp)
trap 'rm -f "${results_file}"' EXIT
quarto_version=$(cat quarto-version.txt)
echo "Quarto version: ${quarto_version} (${QUARTO_CHANNEL})"

ext_count=$(jq 'length' clone-manifest.json)

docker_run_render() {
  local workdir="$1" log_dir="$2" render_dir="$3"
  shift 3
  timeout 300 docker run --rm \
    --user "${DOCKER_USER}" \
    "${DOCKER_SECURITY_OPTS[@]}" \
    "$@" \
    -e QUARTO_CHROMIUM="/usr/bin/google-chrome-stable" \
    -e HOME="${workdir}" \
    -e XDG_CACHE_HOME="${workdir}/.cache" \
    -v "${workdir}:${workdir}" \
    -v "${log_dir}:${log_dir}" \
    -w "${render_dir}" \
    render-image
}

render_extension() {
  local i="$1"

  local id ext_type status workdir render_dir log_dir log_path ext
  IFS=$'\t' read -r id ext_type status workdir render_dir log_dir log_path < <(
    jq -r ".[${i}] | [.id // \"\", .type // \"\", .clone_status // \"\", .workdir // \"\", .render_dir // \"\", .log_dir // \"\", .log_path // \"\"] | @tsv" clone-manifest.json
  )
  ext=$(jq -c ".[${i}].ext" clone-manifest.json)

  if [[ -z "${id}" ]] || [[ -z "${ext_type}" ]] || [[ -z "${status}" ]] || [[ -z "${workdir}" ]] || [[ -z "${render_dir}" ]] || [[ -z "${log_dir}" ]] || [[ -z "${log_path}" ]]; then
    echo "::warning::Skipping malformed clone-manifest entry at index ${i}."
    return
  fi

  if [[ "${status}" == "pass" ]]; then
    printf '%s\n' "${ext}" >"${workdir}/ext-meta.json"

    # Dependency source policy check
    if [[ -f "${render_dir}/renv.lock" ]] || [[ -f "${render_dir}/uv.lock" ]] || [[ -f "${render_dir}/requirements.txt" ]]; then
      if ! (cd "${render_dir}" && EXT_ID="${id}" bash "${SCRIPT_DIR}/dependency-policy.sh") \
        >>"${log_dir}/stdout.log" 2>>"${log_dir}/stderr.log"; then
        echo "::warning::Dependency policy check failed for ${id}."
        status="fail"
      fi
    fi

    # Phase A: Install dependencies (network allowed)
    if [[ "${status}" == "pass" ]] && { [[ -f "${render_dir}/renv.lock" ]] || [[ -f "${render_dir}/uv.lock" ]] || [[ -f "${render_dir}/requirements.txt" ]]; }; then
      dep_sources=()
      [[ -f "${render_dir}/renv.lock" ]] && dep_sources+=("renv.lock")
      [[ -f "${render_dir}/uv.lock" ]] && dep_sources+=("uv.lock")
      [[ -f "${render_dir}/requirements.txt" ]] && dep_sources+=("requirements.txt")
      echo "Dependency install phase for ${id}: ${dep_sources[*]}" >>"${log_dir}/stdout.log"
      docker_run_render "${workdir}" "${log_dir}" "${render_dir}" \
        --security-opt=seccomp=default \
        --security-opt=apparmor=docker-default \
        -e EXT_ID="${id}" \
        -e LOG_DIR="${log_dir}" \
        bash <<'DEPS_SCRIPT' || status="fail"
set -euo pipefail

if [[ -f renv.lock ]]; then
  echo "Installing R dependencies from renv.lock for ${EXT_ID}." >>"${LOG_DIR}/stdout.log"
  Rscript -e 'if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")' \
    >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
    echo "renv install failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
    exit 1
  }
  Rscript -e 'renv::restore()' \
    >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
    echo "renv restore failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
    exit 1
  }
fi
if [[ -f uv.lock ]] || [[ -f requirements.txt ]]; then
  echo "Installing Python dependencies for ${EXT_ID}." >>"${LOG_DIR}/stdout.log"
  uv venv >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
    echo "uv venv failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
    exit 1
  }
  source .venv/bin/activate
  if [[ -f uv.lock ]]; then
    uv sync >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
      echo "uv sync failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
      exit 1
    }
  elif [[ -f requirements.txt ]]; then
    uv pip install -r requirements.txt >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
      echo "uv pip install failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
      exit 1
    }
  fi
fi
DEPS_SCRIPT
    fi

    # Phase B: Render (air-gapped, no network)
    if [[ "${status}" == "pass" ]]; then
      docker_run_render "${workdir}" "${log_dir}" "${render_dir}" \
        --network=none \
        -e EXT_TYPE="${ext_type}" \
        -e EXT_ID="${id}" \
        -e WORKDIR="${workdir}" \
        -e LOG_DIR="${log_dir}" \
        bash <<'RENDER_SCRIPT' || status="fail"
set -euo pipefail

# Activate venv if it was created during dependency install
if [[ -f .venv/bin/activate ]]; then
  source .venv/bin/activate
fi

render_idx=0
if [[ -f _quarto.yml ]] || [[ -f _quarto.yaml ]]; then
  quarto render --log "${WORKDIR}/render-${render_idx}.log" --log-level info \
    >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || exit 1
elif [[ "${EXT_TYPE}" == "document" ]]; then
  qmd_files=$(jq -r '.qmd_files[]?' "${WORKDIR}/ext-meta.json")
  while IFS= read -r qmd; do
    if [[ "${qmd}" == /* ]] || [[ "${qmd}" == *".."* ]]; then continue; fi
    if [[ -f "${qmd}" ]]; then
      quarto render "${qmd}" --log "${WORKDIR}/render-${render_idx}.log" --log-level info \
        >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || exit 1
      render_idx=$((render_idx + 1))
    fi
  done <<< "${qmd_files}"
else
  while IFS= read -r -d '' qmd; do
    quarto render "${qmd}" --log "${WORKDIR}/render-${render_idx}.log" --log-level info \
      >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || exit 1
    render_idx=$((render_idx + 1))
  done < <(find . -name '*.qmd' -not -path './_extensions/*' -print0)
fi
RENDER_SCRIPT
    fi
  fi

  # Copy render logs to log directory
  find "${workdir}" -maxdepth 1 -name 'render-*.log' -type f -exec cp --no-dereference {} "${log_dir}/" \; 2>/dev/null || true

  if [[ "${status}" == "pass" ]]; then
    echo "Result: ${id} PASSED"
  else
    echo "::warning::Result: ${id} FAILED"
  fi

  # Clean up workdir now that logs are copied
  rm -rf "${workdir}"

  jq -cn \
    --arg id "${id}" \
    --arg t "${ext_type}" \
    --arg s "${status}" \
    --arg l "${log_path}" \
    --arg qv "${quarto_version}" \
    --arg qc "${QUARTO_CHANNEL}" \
    '{id: $id, type: $t, status: $s, log: $l, quarto_version: $qv, quarto_channel: $qc}' \
    >>"${results_file}"
}

for ((i = 0; i < ext_count; i++)); do
  render_extension "${i}"
done

if [[ -s "${results_file}" ]]; then
  jq -sc '.' "${results_file}" >results.json
else
  echo '[]' >results.json
fi
echo "Results:"
jq '.' results.json
