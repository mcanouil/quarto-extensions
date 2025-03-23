#!/usr/bin/env bash

set -e

BRANCH=${BRANCH:-"quarto-wizard"}
COMMIT=${COMMIT:-"ci: update extensions details"}
CSV_FILE=${CSV_FILE:-"extensions/quarto-extensions.csv"}

JSON_FILE="quarto-extensions.json"
echo "*" > .gitignore
echo "!${JSON_FILE}" > .gitignore

previous_owner=""
previous_author=""

EXTENSION_DETAILS=()
while IFS=, read -r entry; do
  echo "Processing entry: ${entry}"
  repo=$(echo "${entry}" | cut -d'/' -f1,2)
  repo_info=$(
    gh repo view "${repo}" \
      --json name,nameWithOwner,owner,description,openGraphImageUrl,stargazerCount,licenseInfo,url,latestRelease,createdAt,updatedAt,repositoryTopics,defaultBranchRef \
      --jq '{
        name: .name,
        title: (.name | split("-|_"; "") | map(select(. != "quarto" and . != "template")) | join(" ") | ascii_upcase),
        nameWithOwner: (.nameWithOwner | ascii_downcase),
        owner: (.owner.login | ascii_downcase),
        description: (if .description == "" then "No description available." else .description end),
        openGraphImageUrl: .openGraphImageUrl,
        stargazerCount: (.stargazerCount // 0),
        licenseInfo: (.licenseInfo.name // "none"),
        url: .url,
        latestRelease: (.latestRelease.tagName // "none"),
        latestReleaseUrl: (.latestRelease.url // null),
        createdAt: .createdAt,
        updatedAt: .updatedAt,
        defaultBranchRef: .defaultBranchRef.name,
        repositoryTopics: (if .repositoryTopics == null then [] else
        [.repositoryTopics[].name |
          sub("^quarto-"; "") |
          sub("-template[s]*"; "") |
          if test("filters$|formats$|journals$") then sub("s$"; "") else . end |
          sub("reveal-js"; "reveal.js") |
          sub("revealjs"; "reveal.js") |
          select(test("quarto|extension|template|^pub$") | not)] | unique
        end)
      }'
  )

  owner=$(echo "${repo_info}" | jq -r ".owner")
  if [[ "${owner}" == "${previous_owner}" ]]; then
    author="${previous_author}"
  else
    author=$(gh api "users/${owner}" --jq ".name")
    if [[ -z "${author}" ]]; then
      author="${owner}"
    fi
    previous_owner="${owner}"
    previous_author="${author}"
  fi
  repo_info=$(echo "${repo_info}" | jq --arg author "${author}" '. + {author: $author}')

  repo_subdirectory=$(echo "${entry}" | cut -d'/' -f3-)
  if [[ -n "${repo_subdirectory}" ]]; then
    repo_subdirectory="${repo_subdirectory}/"
    repo_recursive="?recursive=1"
  fi
  repo_branch=$(echo "${repo_info}" | jq -r ".defaultBranchRef")
  repo_template=$(
    gh api \
    -X GET "repos/${repo}/git/trees/${repo_branch}${repo_recursive}" \
    --jq ".tree[] | select(.path | endswith(\"${repo_subdirectory}template.qmd\")) | .path"
  )
  if [[ "${repo_template}" == "template.qmd" ]]; then
    repo_info=$(echo "${repo_info}" | jq '. + {template: true} | .repositoryTopics += ["template"]')
  fi

  repo_info=$(echo "${repo_info}" | jq --arg entry "${entry,,}" '{($entry): .}')
  EXTENSION_DETAILS+=("${repo_info}")
done < <(sort -f data/${CSV_FILE})
json_output=$(printf "%s\n" "${EXTENSION_DETAILS[@]}" | jq -s 'add')
echo "${json_output}" > "${JSON_FILE}"

git add ${JSON_FILE} || echo "No changes to commit"
git commit --allow-empty -m "${COMMIT}"
git push --force origin ${BRANCH}
