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
  local max_attempts=5
  local attempt=0
  local http_code=""
  local mime_type=""
  local downloaded=false
  local placeholder_file="${PLACEHOLDER_IMAGE:-assets/media/github-placeholder.png}"
  local temp_file="${output_file}.tmp"
  local header_file="${output_file}.hdr"

  # Step 1: Delete existing extension.png if it is the same as placeholder
  if [[ -f "${output_file}" ]]; then
    if cmp -s "${output_file}" "${placeholder_file}"; then
      echo "Existing image is identical to placeholder, removing"
      git rm --cached "${output_file}" 2>/dev/null || true
      rm -f "${output_file}"
    fi
  fi

  # Step 2: Download with redirect following, HTTP-status checking, and backoff.
  # opengraph.githubassets.com rate-limits per IP (HTTP 429 + Retry-After), so a
  # transient failure must not be mistaken for "no image".
  while [[ ${attempt} -lt ${max_attempts} ]]; do
    attempt=$((attempt + 1))
    http_code=$(curl -L -s -o "${temp_file}" -D "${header_file}" \
      -w '%{http_code}' "${image_url}" || echo "000")
    mime_type=$(file --mime-type -b "${temp_file}" 2>/dev/null || echo "")

    if [[ "${http_code}" == "200" && "${mime_type}" == "image/png" ]]; then
      downloaded=true
      break
    fi

    rm -f "${temp_file}"

    if [[ "${http_code}" == "429" || "${http_code}" == "503" ]]; then
      local retry_after
      retry_after=$(grep -i '^retry-after:' "${header_file}" 2>/dev/null | tail -n 1 | tr -d '\r' | awk '{print $2}')
      if [[ ! "${retry_after}" =~ ^[0-9]+$ ]]; then
        retry_after=$((attempt * 5))
      fi
      if [[ "${retry_after}" -gt 30 ]]; then
        retry_after=30
      fi
      echo "::warning title=Image Rate Limited::${image_url} returned HTTP ${http_code}, retrying in ${retry_after}s (attempt ${attempt}/${max_attempts})"
      sleep "${retry_after}"
      continue
    fi

    echo "Note: image fetch returned HTTP ${http_code}, mime ${mime_type:-unknown} (attempt ${attempt}/${max_attempts})."
    sleep $((attempt * 2))
  done

  # Step 3: Only keep a confirmed download, and never downgrade a real image to
  # the placeholder on transient failure.
  if [[ "${downloaded}" == true ]]; then
    if cmp -s "${temp_file}" "${placeholder_file}"; then
      echo "Downloaded image is identical to placeholder, removing"
      rm -f "${temp_file}"
    else
      mv "${temp_file}" "${output_file}"
    fi
  fi

  # Step 4: Clean up temporary files and return result
  rm -f "${temp_file}" "${header_file}"
  if [[ -f "${output_file}" ]]; then
    echo "${output_file}"
  else
    echo "::warning title=Image Unavailable::Using placeholder for ${image_url}"
    echo "${placeholder_file}"
  fi
}
