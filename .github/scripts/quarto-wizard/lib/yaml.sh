#!/usr/bin/env bash
# shellcheck shell=bash
# YAML generation functions for quarto-wizard

# Generate extension YAML manifest file
# Arguments:
#   $1  - extension_yaml_file: Output file path
#   $2  - entry_title: Extension title
#   $3  - extension_png_file: Path to extension image
#   $4  - entry_url: GitHub repository URL
#   $5  - entry_author: Author name
#   $6  - owner: GitHub username
#   $7  - entry_created: Creation date (ISO 8601)
#   $8  - entry_updated: Last update date (ISO 8601)
#   $9  - entry_topics: JSON array of topics
#   $10 - entry_license: Licence name
#   $11 - entry_stars: Star count
#   $12 - entry_release: Release version with URL
#   $13 - entry_description: Extension description
#   $14 - yaml_usage_body: Usage string (owner/repo@version)
#   $15 - entry_template: Boolean for template availability
#   $16 - entry_example: Boolean for example availability
#   $17 - entry_contributes: JSON array of contribution types
#   $18 - entry_quarto_required: Quarto version requirement (optional)
generate_extension_yaml() {
  local extension_yaml_file="$1"
  local entry_title="$2"
  local extension_png_file="$3"
  local entry_url="$4"
  local entry_author="$5"
  local owner="$6"
  local entry_created="$7"
  local entry_updated="$8"
  local entry_topics="$9"
  local entry_license="${10}"
  local entry_stars="${11}"
  local entry_release="${12}"
  local entry_description="${13}"
  local yaml_usage_body="${14}"
  local entry_template="${15}"
  local entry_example="${16}"
  local entry_contributes="${17}"
  local entry_quarto_required="${18:-}"

  local author_field
  if [[ -z "${entry_author}" ]]; then
    author_field="author: ${entry_author}"
  else
    author_field="author: \"${entry_author}\""
  fi

  # Build quarto-required field if value exists and is not null
  local quarto_required_line=""
  if [[ -n "${entry_quarto_required}" && "${entry_quarto_required}" != "null" ]]; then
    quarto_required_line="  quarto-required: \"${entry_quarto_required}\"\n"
  fi

  # Generate YAML with quarto-required after contributes
  {
    echo -e "- title: ${entry_title}"
    echo -e "  image: \"/${extension_png_file}\""
    echo -e "  image-alt: \"GitHub repository OpenGraph image for ${entry_url}\""
    echo -e "  github-url: ${entry_url}"
    echo -e "  login: ${owner}"
    echo -e "  ${author_field}"
    echo -e "  author-url: \"/authors/${owner}.qmd\""
    echo -e "  date: \"${entry_created}\""
    echo -e "  file-modified: \"${entry_updated}\""
    echo -e "  categories: ${entry_topics}"
    echo -e "  contributes: ${entry_contributes}"
    if [[ -n "${quarto_required_line}" ]]; then
      echo -en "${quarto_required_line}"
    fi
    echo -e "  license: \"${entry_license}\""
    echo -e "  stars: $(printf "%05d" "${entry_stars}")"
    echo -e "  version: \"${entry_release}\""
    echo -e "  description: |"
    echo -e "    ${entry_description}"
    echo -e "  usage: ${yaml_usage_body}"
    echo -e "  template: ${entry_template}"
    echo -e "  example: ${entry_example}"
  } > "${extension_yaml_file}"
}
