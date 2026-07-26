#!/usr/bin/env bash
# shellcheck shell=bash
# Constants and default values for quarto-wizard

# Default configuration values
readonly DEFAULT_DEBUG_MODE="false"
readonly DEFAULT_FORCE_UPDATE="false"
readonly DEFAULT_EXTENSIONS_DIR="extensions"
readonly DEFAULT_JSON_FILE="quarto-extensions.json"
readonly DEFAULT_BRANCH="quarto-wizard"
readonly DEFAULT_COMMIT="ci: update extensions details"
readonly DEFAULT_CSV_FILE="extensions/quarto-extensions.csv"

# Asset paths
# Compared against the raw download to detect GitHub's generic OpenGraph card.
readonly PLACEHOLDER_IMAGE="assets/media/github-placeholder.png"

# Stored social card geometry. The catalogue renders cards at roughly 300 px
# wide, so 640 px covers high-density displays with room to spare.
readonly IMAGE_WIDTH="${IMAGE_WIDTH:-640}"
readonly IMAGE_QUALITY="${IMAGE_QUALITY:-82}"
