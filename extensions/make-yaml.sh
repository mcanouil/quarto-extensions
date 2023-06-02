#!/usr/bin/env bash

set -e

while IFS=, read -r category repo; do
  # target="extensions/${category}/${repo}"
  # if [ ! -d "${target}" ]; then
  #   git submodule add "https://github.com/${repo}" "${target}"
  # fi
  meta="extensions/yaml/${repo//\//--}.yml"
  # if [ ! -f "${meta}" ]; then
    yaml_name="- name: $(basename ${repo})"
    yaml_path="path: https://github.com/${repo}"
    repoowner=$(gh repo view --json owner --jq ".owner.login" "${repo}")
    author=$(gh api "https://api.github.com/users/${repoowner}" --jq ".name")
    yaml_author="author: \"[${author}](https://github.com/${repoowner}/)\""
    description=$(gh repo view --json description --jq ".description" "${repo}")
    yaml_usage="  \n    \`\`\`sh\n    quarto add ${repo}\n    \`\`\`"
    yaml_description="description: |\n    ${description}${yaml_usage}"
    yaml_categories="categories: [${category}]"
    echo -e "${yaml_name}\n  ${yaml_path}\n  ${yaml_author}\n  ${yaml_description}\n  ${yaml_categories}\n" > "${meta}"
  # fi

done < extensions/quarto-extensions.csv
