#!/usr/bin/env bash
# Shared retry helper for test-extensions scripts.
# Source this file; do not execute it directly.

# Retry a command with exponential backoff.
# Usage: retry <max_attempts> <base_delay_seconds> <command...>
# shellcheck disable=SC2034
retry() {
  local max_attempts="$1" base_delay="$2"
  shift 2
  local attempt
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if "$@"; then
      return 0
    fi
    if ((attempt < max_attempts)); then
      sleep $((base_delay * (2 ** (attempt - 1))))
    fi
  done
  return 1
}
