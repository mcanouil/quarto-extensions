#!/usr/bin/env bash
set -euo pipefail

# Enforce log volume limits before artefact upload.
# Inputs (env): LOG_ROOT (optional), MAX_LOG_FILE_BYTES, MAX_LOG_FILES, MAX_LOG_TOTAL_BYTES.

log_root="${LOG_ROOT:-logs}"
max_file_bytes="${MAX_LOG_FILE_BYTES:-10485760}"
max_log_files="${MAX_LOG_FILES:-300}"
max_total_bytes="${MAX_LOG_TOTAL_BYTES:-104857600}"

if [[ ! -d "${log_root}" ]]; then
  echo "No log directory '${log_root}' found. Skipping log limit checks."
  exit 0
fi

if [[ ! "${max_file_bytes}" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "${max_log_files}" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "${max_total_bytes}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid log limit configuration."
  exit 1
fi

log_count=0
total_bytes=0
while IFS= read -r -d '' file; do
  size=$(stat -f '%z' "${file}")
  log_count=$((log_count + 1))
  total_bytes=$((total_bytes + size))

  if [[ "${log_count}" -gt "${max_log_files}" ]]; then
    echo "::error::Log file count ${log_count} exceeds limit ${max_log_files}."
    exit 1
  fi
  if [[ "${size}" -gt "${max_file_bytes}" ]]; then
    echo "::error::Log file '${file}' is ${size} bytes, exceeds limit ${max_file_bytes}."
    exit 1
  fi
  if [[ "${total_bytes}" -gt "${max_total_bytes}" ]]; then
    echo "::error::Total log size ${total_bytes} bytes exceeds limit ${max_total_bytes}."
    exit 1
  fi
done < <(find "${log_root}" -type f -print0)

echo "Log limits OK: files=${log_count}, bytes=${total_bytes}."
