#!/usr/bin/env bash

set -e

mkdir -p extensions/yaml
declare -A repos

while IFS=, read -r category repo; do
  repos["$repo"]=1
  meta="extensions/yaml/${repo//\//--}.yml"
  if [[ ! -f "${meta}" || (-f "${meta}" && $(find "$meta" -mtime +30)) ]]; then
    yaml_name="- name: $(basename ${repo})"
    yaml_path="path: https://github.com/${repo}"
    repoowner=$(gh repo view --json owner --jq ".owner.login" "${repo}")
    author=$(gh api "users/${repoowner}" --jq ".name")
    if [[ -z "${author}" ]]; then
      author=$(gh api "users/${repoowner}" --jq ".login")
    fi
    yaml_author="author: \"[${author}](https://github.com/${repoowner}/)\""
    description=$(gh repo view --json description --jq ".description" "${repo}")
    if [[ -z "${description}" ]]; then
      description="No description available"
    fi
    description=$(echo "${description}" | sed 's/^[[:space:]]*//')
    topics=$(gh api "repos/${repo}/topics" --jq ".names")
    topics=$(echo "${topics}" | jq -r 'map(select(.) | sub("^quarto-"; "") | sub("-template[s]*"; "") | if test("filters$|formats$|journals$") then sub("s$"; "") else . end)')
    topics=$(echo "${topics}" | jq -r 'map(select(. | test("quarto|extension|^pub$") | not))')
    topics=$(echo "${topics}" | jq -r 'unique')
    yaml_usage="\n    \n    \`\`\`sh\n    quarto add ${repo}\n    \`\`\`"
    yaml_description="description: |\n    ${description}${yaml_usage}"
    yaml_type="type: [${category}]"
    yaml_categories="categories: ${topics}"
    echo -e "${yaml_name}\n  ${yaml_path}\n  ${yaml_author}\n  ${yaml_description}\n  ${yaml_type}\n  ${yaml_categories}\n" > "${meta}"
  fi
done < extensions/quarto-extensions.csv

for yaml in extensions/yaml/*.yml; do
  repo_yaml=$(basename "${yaml}" .yml)
  repo_yaml=${repo_yaml//--/\/}
  if [[ -z ${repos["${repo_yaml%.*}"]} ]]; then
    echo "Removing ${yaml} as its repo is not or no longer listed in the CSV file."
    rm "${yaml}"
  fi
done
