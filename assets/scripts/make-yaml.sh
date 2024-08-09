#!/usr/bin/env bash

set -e

mkdir -p extensions/yaml
mkdir -p authors

# Dictionary to store the repositories
# declare -A repos
# repos["$repo"]=1

author_listing_ref="assets/quarto/_author-listing.qmd"
previous_repo_owner=""

sort -f extensions/quarto-extensions.csv | while IFS=, read -r entry; do
  repo=$(echo "${entry}" | cut -d'/' -f1,2)
  author_listing="authors/${repo%%/*}.qmd"
  meta="extensions/yaml/${repo//\//--}.yml"
  if [[ ! -f "${meta}" || (-f "${meta}" && $(find "$meta" -mtime +30)) ]]; then
    repo_info=$(gh repo view --json owner,description,createdAt,updatedAt,latestRelease,licenseInfo,stargazerCount,repositoryTopics "${repo}")
    repo_created=$(echo "${repo_info}" | jq -r ".createdAt")
    repo_release=$(echo "${repo_info}" | jq -r ".latestRelease.tagName")
    if [[ "${repo_release}" = "null" ]]; then
      repo_release="none"
      repo_updated=$(echo "${repo_info}" | jq -r ".updatedAt")
      yaml_usage_body="${entry}"
    else
      repo_release_url=$(echo "${repo_info}" | jq -r ".latestRelease.url")
      yaml_usage_body="${entry}@${repo_release}"
      repo_release="[${repo_release#v}]($repo_release_url)"
      repo_updated=$(echo "${repo_info}" | jq -r ".latestRelease.publishedAt")
    fi
    yaml_usage_header="\n    \n    \`\`\`{.sh filename='Terminal'}\n    quarto add "
    yaml_usage_footer="\n    \`\`\`\n"
    yaml_usage="${yaml_usage_header}${yaml_usage_body}${yaml_usage_footer}"
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
    extension_title=$(basename "${repo}")
    echo -e \
      "- title: ${extension_title#quarto-}\n" \
      " github-url: https://github.com/${repo}\n" \
      " author: \"${repo_author}\"\n" \
      " author-url: \"/${author_listing}\"\n" \
      " date: \"${repo_created}\"\n" \
      " file-modified: \"${repo_updated}\"\n" \
      " categories: ${repo_topics}\n" \
      " license: \"${repo_license}\"\n" \
      " stars: \"$(printf "%05d\n" ${repo_stars})\"\n" \
      " version: \"${repo_release}\"\n" \
      " description: |\n    ${repo_description}\n${yaml_usage}\n" \
      > "${meta}"
    if [[ "${repo_owner}" == "${previous_repo_owner}" ]]; then
      count_extensions=$((count_extensions+1))
      count_stars=$((count_stars+repo_stars))
    else
      previous_repo_owner=${repo_owner}
      count_extensions=1
      count_stars=${repo_stars}
    fi
    sed \
      -e "s/<<github-username>>/${repo%%/*}/g" \
      -e "s/<<github-stars>>/${count_stars}/g" \
      -e "s/<<github-stars-string>>/$(printf "%05d\n" ${count_stars})/g" \
      -e "s/<<extensions-count>>/${count_extensions}/g" \
      -e "s:<<github-repo>>:${repo}:g" \
      -e "s/<<github-name>>/${repo_author}/g" \
      "${author_listing_ref}" > "${author_listing}"
  fi
done

echo -e "extensions: $(wc -l < extensions/quarto-extensions.csv | tr -d ' ')\nauthors: $(ls -1 authors | wc -l | tr -d ' ')" > _variables.yml
