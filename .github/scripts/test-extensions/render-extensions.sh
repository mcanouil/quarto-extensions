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

render_count=0
ext_count=$(jq 'length' clone-manifest.json)

docker_run_render() {
  local run_timeout="$1" workdir="$2" log_dir="$3" render_dir="$4"
  shift 4
  timeout "${run_timeout}" docker run --rm -i \
    --user "${DOCKER_USER}" \
    "${DOCKER_SECURITY_OPTS[@]}" \
    "$@" \
    -e NO_COLOR=1 \
    -e QUARTO_CHROMIUM="/usr/bin/google-chrome-stable" \
    -e HOME="${workdir}" \
    -e XDG_CACHE_HOME="${workdir}/.cache" \
    -e TEXMFVAR="/tmp/texmf-var" \
    -e TEXMFCONFIG="/tmp/texmf-config" \
    -v "${workdir}:${workdir}" \
    -v "${log_dir}:${log_dir}" \
    -w "${render_dir}" \
    render-image \
    bash
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
    if [[ -f "${render_dir}/renv.lock" ]] || [[ -f "${render_dir}/uv.lock" ]] || [[ -f "${render_dir}/requirements.txt" ]] || [[ -f "${render_dir}/Project.toml" ]] || [[ -f "${render_dir}/JuliaProject.toml" ]]; then
      if ! (cd "${render_dir}" && EXT_ID="${id}" bash "${SCRIPT_DIR}/dependency-policy.sh") \
        >>"${log_dir}/stdout.log" 2>>"${log_dir}/stderr.log"; then
        echo "::warning::Dependency policy check failed for ${id}."
        status="fail"
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
      dep_rc=0
      docker_run_render 600 "${workdir}" "${log_dir}" "${render_dir}" \
        -e EXT_ID="${id}" \
        -e LOG_DIR="${log_dir}" \
        <<'DEPS_SCRIPT' || dep_rc=$?
set -euo pipefail

# Auto-detect R dependencies when no renv.lock is present
if [[ ! -f renv.lock ]]; then
  engines=$(quarto inspect . 2>/dev/null | jq -r '.engines[]?' 2>/dev/null) || engines=""
  if echo "${engines}" | grep -qx "knitr"; then
    echo "Auto-detecting R dependencies for ${EXT_ID} (knitr engine, no renv.lock)." >>"${LOG_DIR}/stdout.log"
    Rscript -e '
      if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")
      deps <- unique(renv::dependencies(quiet = TRUE)[["Package"]])
      deps <- setdiff(deps, rownames(installed.packages()))
      if (length(deps) > 0L) {
        cat("Installing R packages:", paste(deps, collapse = ", "), "\n")
        install.packages(deps, repos = "https://cloud.r-project.org")
      } else {
        cat("No additional R packages to install.\n")
      }
    ' >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
      echo "Auto-detect R dependency install failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
      exit 1
    }
  fi
fi

# Auto-detect Python dependencies when no uv.lock/requirements.txt is present
if [[ ! -f uv.lock ]] && [[ ! -f requirements.txt ]]; then
  engines=$(quarto inspect . 2>/dev/null | jq -r '.engines[]?' 2>/dev/null) || engines=""
  if echo "${engines}" | grep -qx "jupyter"; then
    has_python=false
    while IFS= read -r -d '' qmd; do
      if grep -qP '^\s*```\{python' "${qmd}" 2>/dev/null; then
        has_python=true
        break
      fi
    done < <(find . -name '*.qmd' -not -path './_extensions/*' -print0)

    if [[ "${has_python}" == "true" ]]; then
      echo "Auto-detecting Python dependencies for ${EXT_ID} (jupyter engine, no lock file)." >>"${LOG_DIR}/stdout.log"
      uv venv >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
        echo "uv venv failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
        exit 1
      }
      source .venv/bin/activate

      deps=$(find . -name '*.qmd' -not -path './_extensions/*' -print0 \
        | xargs -0 python3 -c '
import sys, ast, re

stdlib = set(sys.stdlib_module_names) if hasattr(sys, "stdlib_module_names") else set()
imports = set()
chunk_re = re.compile(r"^\s*```\{python[^}]*\}\s*$")
end_re = re.compile(r"^\s*```\s*$")

for path in sys.argv[1:]:
    in_chunk = False
    lines = []
    with open(path) as f:
        for line in f:
            if not in_chunk and chunk_re.match(line):
                in_chunk = True
                lines = []
            elif in_chunk and end_re.match(line):
                in_chunk = False
                source = "\n".join(lines)
                try:
                    tree = ast.parse(source)
                    for node in ast.walk(tree):
                        if isinstance(node, ast.Import):
                            for alias in node.names:
                                imports.add(alias.name.split(".")[0])
                        elif isinstance(node, ast.ImportFrom):
                            if node.module:
                                imports.add(node.module.split(".")[0])
                except SyntaxError:
                    pass
                lines = []
            elif in_chunk:
                lines.append(line.rstrip())

third_party = sorted(imports - stdlib - {"__future__"})
for pkg in third_party:
    print(pkg)
' 2>/dev/null) || deps=""

      if [[ -n "${deps}" ]]; then
        echo "Installing Python packages: ${deps//$'\n'/, }" >>"${LOG_DIR}/stdout.log"
        echo "${deps}" | xargs uv pip install -- \
          >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
          echo "Auto-detect Python dependency install failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
          exit 1
        }
      else
        echo "No additional Python packages to install." >>"${LOG_DIR}/stdout.log"
      fi
    fi
  fi
fi

# Auto-detect Julia dependencies when no Project.toml is present
if [[ ! -f Project.toml ]] && [[ ! -f JuliaProject.toml ]]; then
  engines=$(quarto inspect . 2>/dev/null | jq -r '.engines[]?' 2>/dev/null) || engines=""
  if echo "${engines}" | grep -qx "jupyter"; then
    has_julia=false
    while IFS= read -r -d '' qmd; do
      if grep -qP '^\s*```\{julia' "${qmd}" 2>/dev/null; then
        has_julia=true
        break
      fi
    done < <(find . -name '*.qmd' -not -path './_extensions/*' -print0)

    if [[ "${has_julia}" == "true" ]]; then
      echo "Auto-detecting Julia dependencies for ${EXT_ID} (jupyter engine, no Project.toml)." >>"${LOG_DIR}/stdout.log"

      deps=$(find . -name '*.qmd' -not -path './_extensions/*' -print0 \
        | xargs -0 grep -hP '^\s*(using|import)\s+' 2>/dev/null \
        | sed -E 's/^\s*(using|import)\s+//' \
        | sed -E 's/:.*//' \
        | tr ',' '\n' \
        | sed -E 's/^\s+//; s/\s+$//; s/[.].*//' \
        | grep -E '^[A-Za-z][A-Za-z0-9_]*$' \
        | sort -u \
        | grep -vxF -e Base -e Core -e Main -e Pkg \
            -e InteractiveUtils -e LinearAlgebra -e Random \
            -e Statistics -e Dates -e Printf -e Markdown \
            -e Test -e Logging -e REPL -e Sockets -e UUIDs \
            -e Distributed -e SharedArrays -e SparseArrays \
            -e DelimitedFiles -e Serialization -e Libdl \
            -e Mmap -e Profile -e FileWatching -e Unicode \
            -e TOML -e Downloads -e LazyArtifacts -e Artifacts \
            -e SHA -e NetworkOptions -e StyledStrings \
      ) || deps=""

      if [[ -n "${deps}" ]]; then
        echo "Installing Julia packages: ${deps//$'\n'/, }" >>"${LOG_DIR}/stdout.log"
        pkg_list=$(echo "${deps}" | sed "s/.*/\"&\"/" | paste -sd ',' -)
        julia --project=. -e 'using Pkg; Pkg.add(['"${pkg_list}"'])' \
          >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
          echo "Auto-detect Julia dependency install failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
          exit 1
        }
      else
        echo "No additional Julia packages to install." >>"${LOG_DIR}/stdout.log"
      fi
    fi
  fi
fi

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
if [[ -f Project.toml ]] || [[ -f JuliaProject.toml ]]; then
  echo "Installing Julia dependencies from Project.toml for ${EXT_ID}." >>"${LOG_DIR}/stdout.log"
  julia --project=. -e 'using Pkg; Pkg.instantiate()' \
    >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || {
    echo "Julia Pkg.instantiate failed for ${EXT_ID}." >>"${LOG_DIR}/stderr.log"
    exit 1
  }
fi
DEPS_SCRIPT
      if [[ "${dep_rc}" -eq 124 ]]; then
        echo "Dependency install timed out (exit 124) for ${id}." >>"${log_dir}/stderr.log"
        echo "::warning::Dependency install timed out for ${id}."
        status="fail"
      elif [[ "${dep_rc}" -ne 0 ]]; then
        echo "Dependency install failed (exit ${dep_rc}) for ${id}." >>"${log_dir}/stderr.log"
        echo "::warning::Dependency install failed (exit ${dep_rc}) for ${id}."
        status="fail"
      fi
    fi

    # Phase B: Render
    if [[ "${status}" == "pass" ]]; then
      render_count=$((render_count + 1))
      docker_run_render 300 "${workdir}" "${log_dir}" "${render_dir}" \
        -e EXT_TYPE="${ext_type}" \
        -e EXT_ID="${id}" \
        -e WORKDIR="${workdir}" \
        -e LOG_DIR="${log_dir}" \
        <<'RENDER_SCRIPT' || status="fail"
set -euo pipefail

# Activate venv if it was created during dependency install
if [[ -f .venv/bin/activate ]]; then
  source .venv/bin/activate
fi

render_idx=0

# Pin a CTAN mirror to avoid flaky tlmgr searches via mirror.ctan.org round-robin
if command -v tlmgr >/dev/null 2>&1; then
  tlmgr repository set https://ctan.math.illinois.edu/systems/texlive/tlnet 2>/dev/null || true
  tlmgr update --self >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || true
fi

quarto_render() {
  if ! quarto render "$@" --log "${WORKDIR}/render-${render_idx}.log" --log-level info \
    >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log"; then
    echo "Render failed, retrying once..." >>"${LOG_DIR}/stderr.log"
    quarto render "$@" --log "${WORKDIR}/render-${render_idx}.log" --log-level info \
      >>"${LOG_DIR}/stdout.log" 2>>"${LOG_DIR}/stderr.log" || return 1
  fi
}

render_single_qmd() {
  local qmd="$1"
  local formats
  formats=$(quarto inspect "${qmd}" 2>/dev/null | jq -r '.formats | keys[]' 2>/dev/null) || formats=""
  if [[ -z "${formats}" ]]; then
    quarto_render "${qmd}" || exit 1
    render_idx=$((render_idx + 1))
  else
    while IFS= read -r fmt; do
      quarto_render "${qmd}" --to "${fmt}" || exit 1
      render_idx=$((render_idx + 1))
    done <<< "${formats}"
  fi
}

if [[ -f _quarto.yml ]] || [[ -f _quarto.yaml ]]; then
  quarto_render || exit 1
elif [[ "${EXT_TYPE}" == "document" ]]; then
  qmd_files=$(jq -r '.qmd_files[]?' "${WORKDIR}/ext-meta.json")
  while IFS= read -r qmd; do
    if [[ "${qmd}" == /* ]] || [[ "${qmd}" == *".."* ]]; then continue; fi
    if [[ -f "${qmd}" ]]; then
      render_single_qmd "${qmd}"
    fi
  done <<< "${qmd_files}"
else
  while IFS= read -r -d '' qmd; do
    render_single_qmd "${qmd}"
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

if [[ "${ext_count}" -gt 0 ]] && [[ "${render_count}" -eq 0 ]]; then
  echo "::error::No quarto render was executed for ${ext_count} extensions."
  exit 1
fi

echo "Rendered ${render_count}/${ext_count} extensions."
echo "Results:"
jq '.' results.json
