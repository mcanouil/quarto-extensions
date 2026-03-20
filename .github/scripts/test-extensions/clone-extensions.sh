#!/usr/bin/env bash
set -euo pipefail

# Clone extensions for the test-extensions workflow.
# Inputs (env): QUARTO_CHANNEL, GITHUB_WORKSPACE
# Inputs (files): extensions-batch.json
# Outputs (files): clone-manifest.json, quarto-version.txt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-config.sh
source "${SCRIPT_DIR}/docker-config.sh"

clone_manifest_file=$(mktemp)
trap 'rm -f "${clone_manifest_file}"' EXIT

if [[ ! "${QUARTO_CHANNEL}" =~ ^(release|prerelease)$ ]]; then
  echo "::error::Invalid Quarto channel '${QUARTO_CHANNEL}'."
  exit 1
fi

quarto_version=$(docker run --rm --user vscode \
  --cap-drop=ALL --read-only --network=none \
  render-image quarto --version | head -n 1 | tr -d '\r')
if [[ ! "${quarto_version}" =~ ^[0-9A-Za-z._-]+$ ]]; then
  echo "::error::Unexpected Quarto version format '${quarto_version}'."
  exit 1
fi
echo "Quarto version: ${quarto_version} (${QUARTO_CHANNEL})"
echo "${quarto_version}" >quarto-version.txt

ext_count=$(jq 'length' extensions-batch.json)

is_repo_inaccessible() {
  local id="$1" log_dir="$2"
  if ! git ls-remote --exit-code "https://github.com/${id}.git" HEAD >/dev/null 2>&1; then
    echo "::notice::Skipping ${id}: repository is not publicly accessible without token."
    echo "Skipping ${id}: repository is not publicly accessible without token." >>"${log_dir}/stderr.log"
    return 0
  fi
  return 1
}

docker_run_clone() {
  local workdir="$1" log_dir="$2"
  shift 2
  timeout 300 docker run --rm \
    --user "${DOCKER_USER}" \
    "${DOCKER_SECURITY_OPTS[@]}" \
    -e HOME="${workdir}" \
    -e XDG_CACHE_HOME="${workdir}/.cache" \
    -v "${workdir}:${workdir}" \
    -v "${log_dir}:${log_dir}" \
    -w "${workdir}" \
    render-image \
    "$@"
}

for ((i = 0; i < ext_count; i++)); do
  read -r id ext_type project_path < <(
    jq -r ".[${i}] | [.id // \"\", .type // \"\", .project_path // \"\"] | @tsv" extensions-batch.json
  )

  if [[ -z "${id}" ]] || [[ -z "${ext_type}" ]]; then
    echo "::error::Missing required entry fields at index ${i} in extensions-batch.json."
    exit 1
  fi

  status="pass"
  workdir="${GITHUB_WORKSPACE}/test-${i}"

  if [[ ! "${id}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "::warning::Invalid extension id '${id}'."
    status="fail"
    log_dir="${GITHUB_WORKSPACE}/logs/invalid-id/${QUARTO_CHANNEL}/${quarto_version}"
    log_path="logs/invalid-id/${QUARTO_CHANNEL}/${quarto_version}"
  else
    log_dir="${GITHUB_WORKSPACE}/logs/${id}/${QUARTO_CHANNEL}/${quarto_version}"
    log_path="logs/${id}/${QUARTO_CHANNEL}/${quarto_version}"
  fi

  install -d -m 700 "${workdir}" "${log_dir}" "${workdir}/.cache"
  touch "${log_dir}/stdout.log" "${log_dir}/stderr.log"
  chmod 600 "${log_dir}/stdout.log" "${log_dir}/stderr.log"
  render_dir="${workdir}"

  if [[ "${status}" == "pass" ]]; then
    case "${ext_type}" in
    template | example)
      docker_run_clone "${workdir}" "${log_dir}" \
        quarto use template "${id}" --no-prompt >>"${log_dir}/stdout.log" 2>>"${log_dir}/stderr.log" ||
        status="fail"
      if [[ "${status}" == "fail" ]] && is_repo_inaccessible "${id}" "${log_dir}"; then
        status="skip"
      fi
      ;;
    project | document)
      owner=$(echo "${id}" | cut -d'/' -f1)
      repo=$(echo "${id}" | cut -d'/' -f2)
      docker_run_clone "${workdir}" "${log_dir}" \
        git clone --depth 1 "https://github.com/${owner}/${repo}.git" repo \
        >>"${log_dir}/stdout.log" 2>>"${log_dir}/stderr.log" ||
        status="fail"
      if [[ "${status}" == "fail" ]] && is_repo_inaccessible "${id}" "${log_dir}"; then
        status="skip"
      fi
      if [[ "${status}" == "pass" ]]; then
        if [[ "${ext_type}" == "project" ]] && [[ "${project_path}" != "." ]]; then
          if [[ "${project_path}" == /* ]] || [[ "${project_path}" == *".."* ]]; then
            echo "Invalid project_path '${project_path}' for ${id}." \
              >>"${log_dir}/stderr.log"
            status="fail"
          else
            render_dir="${workdir}/repo/${project_path}"
          fi
        fi
        if [[ "${status}" == "pass" ]] && [[ "${render_dir}" == "${workdir}" ]]; then
          render_dir="${workdir}/repo"
        fi
      fi
      ;;
    *)
      echo "Unknown extension type '${ext_type}' for ${id}." >>"${log_dir}/stderr.log"
      status="fail"
      ;;
    esac
  fi

  ext=$(jq -c ".[${i}]" extensions-batch.json)
  jq -cn \
    --arg id "${id}" \
    --arg t "${ext_type}" \
    --arg s "${status}" \
    --arg wd "${workdir}" \
    --arg rd "${render_dir}" \
    --arg ld "${log_dir}" \
    --arg lp "${log_path}" \
    --argjson ext "${ext}" \
    '{id: $id, type: $t, clone_status: $s, workdir: $wd, render_dir: $rd, log_dir: $ld, log_path: $lp, ext: $ext}' \
    >>"${clone_manifest_file}"
done

if [[ -s "${clone_manifest_file}" ]]; then
  jq -sc '.' "${clone_manifest_file}" >clone-manifest.json
else
  echo '[]' >clone-manifest.json
fi
echo "Cloned ${ext_count} extensions."
