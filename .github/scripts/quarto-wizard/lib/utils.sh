#!/usr/bin/env bash
# shellcheck shell=bash
# Utility functions for quarto-wizard

# Escape backslashes in bash strings
# Arguments:
#   $1 - Input string to escape
# Returns:
#   Escaped string via stdout
escape_bash() {
  local input="${1}"
  local escaped

  # Escape backslash first
  escaped="${input//\\/\\\\}"

  printf '%s' "${escaped}"
}

# Log debug message (only when DEBUG_MODE is true)
# Arguments:
#   $@ - Message to log
log_debug() {
  if [[ "${DEBUG_MODE}" == "true" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Log info message
# Arguments:
#   $@ - Message to log
log_info() {
  echo "[INFO] $*"
}

# Log error message
# Arguments:
#   $@ - Message to log
log_error() {
  echo "[ERROR] $*" >&2
}
