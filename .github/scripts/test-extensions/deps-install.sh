#!/usr/bin/env bash
set -euo pipefail

# Install extension dependencies inside the render container.
# Executed via stdin by render-extensions.sh (docker run ... bash < deps-install.sh).
# Inputs (env): EXT_ID, LOG_DIR
# Inputs (cwd): render_dir contents (lock files, qmd files)

detect_engines() {
	local engines=""
	if [[ -f _quarto.yml ]] || [[ -f _quarto.yaml ]]; then
		engines=$(quarto inspect . 2>/dev/null | jq -r '.engines[]?' 2>/dev/null) || engines=""
	fi
	if [[ -z "${engines}" ]]; then
		while IFS= read -r -d '' qmd; do
			local file_engines
			file_engines=$(quarto inspect "${qmd}" 2>/dev/null | jq -r '.engines[]?' 2>/dev/null) || true
			if [[ -n "${file_engines}" ]]; then
				engines=$(printf '%s\n%s' "${engines}" "${file_engines}")
			fi
		done < <(find . -name '*.qmd' -not -path './_extensions/*' -print0 2>/dev/null)
		engines=$(echo "${engines}" | sort -u | sed '/^$/d')
	fi
	echo "${engines}"
}

engines=$(detect_engines)

# Auto-detect R dependencies when no renv.lock is present
if [[ ! -f renv.lock ]]; then
	if echo "${engines}" | grep -qx "knitr"; then
		echo "Auto-detecting R dependencies for ${EXT_ID} (knitr engine, no renv.lock)." >>"${LOG_DIR}/stdout.log"
		Rscript -e '
      ppm <- Sys.getenv("RENV_CONFIG_REPOS_OVERRIDE", "https://cloud.r-project.org")
      if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv", repos = ppm)
      deps <- unique(renv::dependencies(quiet = TRUE)[["Package"]])
      deps <- setdiff(deps, rownames(installed.packages()))
      if (length(deps) > 0L) {
        cat("Installing R packages:", paste(deps, collapse = ", "), "\n")
        install.packages(deps, repos = ppm)
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
			# shellcheck disable=SC1091 # created at runtime by uv venv
			source .venv/bin/activate

			deps=$(find . -name '*.qmd' -not -path './_extensions/*' -print0 |
				xargs -0 python3 -c '
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

			deps=$(
				find . -name '*.qmd' -not -path './_extensions/*' -print0 |
					xargs -0 grep -hP '^\s*(using|import)\s+' 2>/dev/null |
					sed -E 's/^\s*(using|import)\s+//' |
					sed -E 's/:.*//' |
					tr ',' '\n' |
					sed -E 's/^\s+//; s/\s+$//; s/[.].*//' |
					grep -E '^[A-Za-z][A-Za-z0-9_]*$' |
					sort -u |
					grep -vxF -e Base -e Core -e Main -e Pkg \
						-e InteractiveUtils -e LinearAlgebra -e Random \
						-e Statistics -e Dates -e Printf -e Markdown \
						-e Test -e Logging -e REPL -e Sockets -e UUIDs \
						-e Distributed -e SharedArrays -e SparseArrays \
						-e DelimitedFiles -e Serialization -e Libdl \
						-e Mmap -e Profile -e FileWatching -e Unicode \
						-e TOML -e Downloads -e LazyArtifacts -e Artifacts \
						-e SHA -e NetworkOptions -e StyledStrings
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
	# shellcheck disable=SC1091 # created at runtime by uv venv
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
