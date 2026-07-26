#!/usr/bin/env bash
set -euo pipefail

# Build the client-side catalogue index consumed by index.qmd.
#
# Merges the extension metadata harvested by the Quarto Wizard workflow with the
# render results published by the Test Extensions workflow, projecting both down
# to the fields the cards actually display. The browser fetches the result, so
# every field here costs bandwidth on first load.

EXTENSIONS_FILE="${EXTENSIONS_FILE:-extensions.json}"
RESULTS_FILE="${RESULTS_FILE:-test-results.json}"
OUTPUT_FILE="${OUTPUT_FILE:-extensions-index.json}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-extensions}"

if [[ ! -f "${EXTENSIONS_FILE}" ]]; then
  echo "::error::${EXTENSIONS_FILE} not found; the quarto-wizard branch must be restored first." >&2
  exit 1
fi

if [[ ! -f "${RESULTS_FILE}" ]]; then
  echo "::warning::${RESULTS_FILE} not found; building the index without test results." >&2
  echo '{}' >"${RESULTS_FILE}"
fi

# Map "owner/repo" to the social card that is actually on disk, preferring WebP
# over the legacy PNG so the index stays correct while the data branch is being
# converted. Cards without an image fall back to the placeholder client-side.
images=$(
  find "${EXTENSIONS_DIR}" -mindepth 3 -maxdepth 3 -type f \
    \( -name 'extension.webp' -o -name 'extension.png' \) -print |
    jq -R -s '
      split("\n")
      | map(select(length > 0))
      | group_by(split("/")[1:3] | join("/"))
      | map({key: (.[0] | split("/")[1:3] | join("/")), value: (max)})
      | from_entries
    '
)

jq -n \
  --slurpfile extensions "${EXTENSIONS_FILE}" \
  --slurpfile results "${RESULTS_FILE}" \
  --argjson images "${images}" '
  ($extensions[0] // {}) as $extensions
  | ($results[0] // {}) as $results
  | [
      $extensions
      | to_entries[]
      | .value as $e
      | ($e.nameWithOwner) as $key
      | ($e.latestRelease // "none") as $release
      | {
          key: $key,
          title: $e.title,
          description: ($e.description // ""),
          url: $e.url,
          login: $e.owner,
          author: (if ($e.author // "") == "" or $e.author == "null" then $e.owner else $e.author end),
          created: $e.createdAt,
          modified: $e.pushedAt,
          categories: ($e.repositoryTopics // []),
          contributes: ($e.contributes // []),
          license: ($e.licenseInfo // "none"),
          stars: ($e.stargazerCount // 0),
          quartoRequired: $e.quartoRequired,
          version: (if $release == "none" then null else ($release | sub("^[^0-9]*"; "")) end),
          versionUrl: $e.latestReleaseUrl,
          usage: (if $release == "none" then $key else "\($key)@\($release)" end),
          template: ($e.template // false),
          example: ($e.example // false),
          image: $images[$key],
          tests: [
            ($results[$key].results // [])[]
            | {
                version: .quarto_version,
                channel: .quarto_channel,
                status: .status,
                log: .log,
                date: .date
              }
          ]
        }
    ]
  | sort_by(.modified)
  | reverse
' >"${OUTPUT_FILE}"

count=$(jq 'length' "${OUTPUT_FILE}")
echo "Wrote ${count} extensions to ${OUTPUT_FILE}."
