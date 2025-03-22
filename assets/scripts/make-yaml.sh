#!/usr/bin/env bash

set -e

mkdir -p extensions/yaml
mkdir -p authors

author_listing_ref="assets/quarto/_author-listing.qmd"
previous_repo_owner=""

json_file="quarto-extensions.json"
git fetch origin quarto-wizard:quarto-wizard
git restore --source quarto-wizard -- "${json_file}"

jq -c 'to_entries[]' "${json_file}" | while read -r entry; do
  entry_repo=$(echo "${entry}" | jq -r '.key')
  meta="extensions/yaml/${entry_repo//\//--}.yml"

  entry_owner=$(echo "${entry}" | jq -r '.value.owner')
  author_listing="authors/${entry_owner}.qmd"

  entry_title=$(echo "${entry}" | jq -r '.value.title')
  entry_created=$(echo "${entry}" | jq -r '.value.createdAt')
  entry_updated=$(echo "${entry}" | jq -r '.value.updatedAt')
  entry_url=$(echo "${entry}" | jq -r '.value.url')
  entry_topics=$(echo "${entry}" | jq -r '.value.repositoryTopics' | jq -c 'unique')
  entry_license=$(echo "${entry}" | jq -r '.value.licenseInfo')
  entry_stars=$(echo "${entry}" | jq -r '.value.stargazerCount')
  entry_image=$(echo "${entry}" | jq -r '.value.openGraphImageUrl')
  entry_author=$(echo "${entry}" | jq -r '.value.author')

  entry_description=$(echo "${entry}" | jq -r '.value.description')
  entry_description=$(echo "${entry_description}" | sed 's/^[[:space:]]*//')
  entry_description=$(echo "${entry_description}" | sed -E 's/([^`])(<[^<>]+>)([^`])/\1`\2`\3/g')

  entry_release=$(echo "${entry}" | jq -r '.value.latestRelease')
  yaml_usage_body="${entry_repo}"
  if [[ "${entry_release}" != "none" ]]; then
    entry_release_url=$(echo "${entry}" | jq -r '.value.latestReleaseUrl')
    yaml_usage_body="${entry_repo}@${entry_release}"
    entry_release="[${entry_release#v}](${entry_release_url})"
  fi

  echo -e \
    "- title: ${entry_title}\n" \
    " image: ${entry_image}\n" \
    " image-alt: \"GitHub repository OpenGraph image for ${entry_url}\"\n" \
    " github-url: ${entry_url}\n" \
    " author: \"${entry_author}\"\n" \
    " author-url: \"/${author_listing}\"\n" \
    " date: \"${entry_created}\"\n" \
    " file-modified: \"${entry_updated}\"\n" \
    " categories: ${entry_topics}\n" \
    " license: \"${entry_license}\"\n" \
    " stars: $(printf "%05d\n" ${entry_stars})\n" \
    " version: \"${entry_release}\"\n" \
    " description: |\n    ${entry_description}\n" \
    " usage: ${yaml_usage_body}\n" \
    > "${meta}"

  if [[ "${entry_owner}" == "${previous_entry_owner}" ]]; then
    count_extensions=$((count_extensions+1))
    count_stars=$((count_stars+entry_stars))
  else
    previous_entry_owner=${entry_owner}
    count_extensions=1
    count_stars=${entry_stars}
  fi

  sed \
    -e "s/<<github-username>>/${entry_owner}/g" \
    -e "s/<<github-stars>>/${count_stars}/g" \
    -e "s/<<github-stars-string>>/$(printf "%05d\n" ${count_stars})/g" \
    -e "s/<<extensions-count>>/${count_extensions}/g" \
    -e "s:<<github-repo>>:${entry_repo}:g" \
    -e "s/<<github-name>>/${entry_author}/g" \
    "${author_listing_ref}" > "${author_listing}"
done

echo -e "extensions: $(wc -l < extensions/quarto-extensions.csv | tr -d ' ')\nauthors: $(ls -1 authors | wc -l | tr -d ' ')" > _variables.yml
