#!/usr/bin/env bash

if [ -z "${QUARTO_PROJECT_RENDER_ALL}" ]; then
  exit 0
fi

set -e

EXTENSIONS_DIR="extensions"

git fetch origin quarto-wizard:quarto-wizard
git restore --source=quarto-wizard --worktree "${EXTENSIONS_DIR}"

mkdir -p authors

echo -e "extensions: $(find extensions -name "extension.json" | wc -l | tr -d ' ')\nauthors: $(find extensions -name "author.json" | wc -l | tr -d ' ')" > _variables.yml

for owner in ${EXTENSIONS_DIR}/*/; do
  owner=$(basename "${owner}")
  owner_image=$(find "${EXTENSIONS_DIR}/${owner}" -type f \( -name "author.jpg" -o -name "author.png" \) | head -n 1)
  count_stars=$(find "${EXTENSIONS_DIR}/${owner}/" -mindepth 2 -name "extension.json" -exec jq '.[].stargazerCount' {} + | awk '{s+=$1} END {print s}')
  count_extensions=$(find "${EXTENSIONS_DIR}/${owner}/" -name "extension.json" | wc -l | tr -d ' ')
  author=$(jq -r '.name // .login' "${EXTENSIONS_DIR}/${owner}/author.json")

  sed \
    -e "s/<<github-username>>/${owner}/g" \
    -e "s:<<github-username-image>>:/${owner_image}:g" \
    -e "s/<<github-stars>>/${count_stars}/g" \
    -e "s/<<github-stars-string>>/$(printf "%05d\n" ${count_stars})/g" \
    -e "s/<<extensions-count>>/${count_extensions}/g" \
    -e "s/<<github-name>>/${author}/g" \
    "assets/quarto/_author-listing.qmd" >"authors/${owner}.qmd"
done
