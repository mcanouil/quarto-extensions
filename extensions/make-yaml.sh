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
    repo_info=$(gh repo view --json owner,description,latestRelease,licenseInfo,stargazerCount,repositoryTopics "${repo}")
    # repo_readme=$(gh api "repos/${repo}/contents/README.md" -H "Accept: application/vnd.github.v3.raw")
    repo_owner=$(echo "${repo_info}" | jq -r ".owner.login")
    repo_author=$(gh api "users/${repo_owner}" --jq ".name")
    if [[ -z "${repo_author}" ]]; then
      repo_author=$(gh api "users/${repo_owner}" --jq ".login")
    fi
    yaml_author="author: \"[${repo_author}](https://github.com/${repo_owner}/)\""
    repo_description=$(echo "${repo_info}" | jq -r ".description")
    if [[ -z "${repo_description}" ]]; then
      repo_description="No description available"
    fi
    repo_description=$(echo "${repo_description}" | sed 's/^[[:space:]]*//')
    repo_topics=$(echo "${repo_info}" | jq -r ".repositoryTopics")
    if [[ "${repo_topics}" = "null" ]]; then
      repo_topics="[]"
    else
      repo_topics=$(echo "${repo_topics}" | jq -r "map(.name)")
      repo_topics=$(echo "${repo_topics}" | jq -r 'map(select(.) | sub("^quarto-"; ""))')
      repo_topics=$(echo "${repo_topics}" | jq -r 'map(select(.) | sub("-template[s]*"; ""))')
      repo_topics=$(echo "${repo_topics}" | jq -r 'map(select(.) | if test("filters$|formats$|journals$") then sub("s$"; "") else . end)')
      repo_topics=$(echo "${repo_topics}" | jq -r 'map(select(.) | sub("reveal-js"; "reveal.js") | sub("revealjs"; "reveal.js"))')
      repo_topics=$(echo "${repo_topics}" | jq -r 'map(select(. | test("quarto|extension|^pub$") | not))')
      repo_topics=$(echo "${repo_topics}" | jq -c 'unique')
    fi
    yaml_usage="\n    \n    \`\`\`sh\n    quarto add ${repo}\n    \`\`\`"
    yaml_description="description: |\n    ${repo_description}${yaml_usage}"
    yaml_type="type: [${category}]"
    yaml_categories="categories: ${repo_topics}"
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
