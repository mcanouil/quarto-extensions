#!/usr/bin/env bash
# shellcheck shell=bash
# Image handling functions for quarto-wizard

# Download and determine author image file format
# Arguments:
#   $1 - Base file path (without extension)
#   $2 - Owner (GitHub username)
# Returns:
#   Full path to image file via stdout
author_image_file() {
  local base_file="$1"
  local owner="$2"

  if [[ -f "${base_file}.png" ]]; then
    echo "${base_file}.png"
    return
  elif [[ -f "${base_file}.jpg" ]]; then
    echo "${base_file}.jpg"
    return
  fi

  curl -L -s -o "${base_file}" "https://github.com/${owner}.png"

  local mime_type
  mime_type=$(file --mime-type -b "${base_file}")

  local extension
  case "${mime_type}" in
    image/jpeg) extension="jpg" ;;
    image/png) extension="png" ;;
    *) extension="png" ;;
  esac

  mv "${base_file}" "${base_file}.${extension}"
  echo "${base_file}.${extension}"
}

# Download extension image with retry logic and placeholder detection
# Arguments:
#   $1 - Image URL to download
#   $2 - Output file path
# Returns:
#   Final image path via stdout (either downloaded image or placeholder)
extension_image_file() {
  local image_url="$1"
  local output_file="$2"
  local attempt=0
  local mime_type=""
  local placeholder_file="${PLACEHOLDER_IMAGE:-assets/media/github-placeholder.png}"
  local temp_file="${output_file}.tmp"

  # Step 1: Delete existing extension.png if it is the same as placeholder
  if [[ -f "${output_file}" ]]; then
    if cmp -s "${output_file}" "${placeholder_file}"; then
      echo "Existing image is identical to placeholder, removing"
      git rm --cached "${output_file}" 2>/dev/null || true
      rm -f "${output_file}"
    fi
  fi

  # Step 2: Try to download and update extension.png using a temporary file
  while [[ ${attempt} -lt 3 ]]; do
    curl -s -o "${temp_file}" "${image_url}"
    mime_type=$(file --mime-type -b "${temp_file}")
    if [[ "${mime_type}" == "image/png" ]]; then
      break
    fi
    if [[ "${mime_type}" != "image/png" ]]; then
      echo "Note: image is not a PNG file. $((attempt + 1)) attempt(s) to download."
      rm -f "${temp_file}"
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  # Step 2 continued: Only keep downloaded image if it is not the same as placeholder
  if [[ -f "${temp_file}" && "${mime_type}" == "image/png" ]]; then
    if cmp -s "${temp_file}" "${placeholder_file}"; then
      echo "Downloaded image is identical to placeholder, removing"
      rm -f "${temp_file}"
    else
      mv "${temp_file}" "${output_file}"
    fi
  fi

  # Step 3: Clean up temporary file and return result
  rm -f "${temp_file}"
  if [[ -f "${output_file}" ]]; then
    echo "${output_file}"
  else
    echo "${placeholder_file}"
  fi
}
