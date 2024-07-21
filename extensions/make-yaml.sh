#!/usr/bin/env bash

set -e

mkdir -p extensions/yaml
mkdir -p extensions/authors
# mkdir -p extensions/readme
declare -A repos

while IFS=, read -r entry; do
  repo=$(echo "${entry}" | cut -d'/' -f1,2)
  repos["$repo"]=1
  meta="extensions/yaml/${repo//\//--}.yml"
  if [[ ! -f "${meta}" || (-f "${meta}" && $(find "$meta" -mtime +30)) ]]; then
    repo_info=$(gh repo view --json owner,description,createdAt,updatedAt,latestRelease,licenseInfo,stargazerCount,repositoryTopics "${repo}")
    repo_created=$(echo "${repo_info}" | jq -r ".createdAt")
    repo_release=$(echo "${repo_info}" | jq -r ".latestRelease.tagName")
    if [[ "${repo_release}" = "null" ]]; then
      repo_release="none"
      repo_updated=$(echo "${repo_info}" | jq -r ".updatedAt")
      yaml_usage="\n    \n    \`\`\`sh\n    quarto add ${entry}\n    \`\`\`"
    else
      repo_release_url=$(echo "${repo_info}" | jq -r ".latestRelease.url")
      yaml_usage="\n    \n    \`\`\`sh\n    quarto add ${entry}@${repo_release}\n    \`\`\`"
      repo_release="[${repo_release#v}]($repo_release_url)"
      repo_updated=$(echo "${repo_info}" | jq -r ".latestRelease.publishedAt")
    fi
    repo_license=$(echo "${repo_info}" | jq -r ".licenseInfo.name")
    if [[ "${repo_license}" = "null" ]]; then
      repo_license="No license specified"
    fi
    repo_stars=$(echo "${repo_info}" | jq -r ".stargazerCount")
    if [[ "${repo_stars}" = "null" ]]; then
      repo_stars="0"
    fi
    repo_owner=$(echo "${repo_info}" | jq -r ".owner.login")
    repo_author=$(gh api "users/${repo_owner}" --jq ".name")
    if [[ -z "${repo_author}" ]]; then
      repo_author=$(gh api "users/${repo_owner}" --jq ".login")
    fi
    repo_description=$(echo "${repo_info}" | jq -r ".description")
    if [[ -z "${repo_description}" ]]; then
      repo_description="No description available"
    fi
    repo_description=$(echo "${repo_description}" | sed 's/^[[:space:]]*//')
    repo_description=$(echo "${repo_description}" | sed -E 's/([^`])(<[^<>]+>)([^`])/\1`\2`\3/g')
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
    author_listing="extensions/authors/${repo%%/*}.qmd"
    echo -e \
      "- title: $(basename ${repo})\n" \
      " path: https://github.com/${repo}\n" \
      " author: \"[${repo_author}](/${author_listing})\"\n" \
      " date: \"${repo_created}\"\n" \
      " file-modified: \"${repo_updated}\"\n" \
      " categories: ${repo_topics}\n" \
      " license: \"${repo_license}\"\n" \
      " stars: \"[$(printf "%05d\n" ${repo_stars})]{style='display: none;'}[[\`&bigstar;\`{=html}]{style='color:#dcbe50;'} ${repo_stars}](https://github.com/${repo}/stargazers)\"\n" \
      " version: \"${repo_release}\"\n" \
      " description: |\n    ${repo_description}\n${yaml_usage}\n" \
      > "${meta}"
    # echo -e $(gh api "repos/${repo}/contents/README.md" -H "Accept: application/vnd.github.v3.raw") > "${readme}"
    if [[ ! -f "${author_listing}" ]]; then
      sed -e "s/<<author>>/${repo%%/*}/g" -e "s/<<fancy-author>>/\[${repo_author}\]\(https:\/\/github.com\/${repo_owner}\)/g" extensions/_author-listing.qmd > "${author_listing}"
    fi
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
