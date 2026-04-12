#!/usr/bin/env bash
set -euo pipefail

# Inject test results from test-results.json into extension.yml files.
# Each extension.yml gets a test-results YAML block appended if matching
# results exist in test-results.json.

RESULTS_FILE="test-results.json"

if [[ ! -f "${RESULTS_FILE}" ]]; then
	echo "No ${RESULTS_FILE} found, skipping injection."
	exit 0
fi

for yml_path in extensions/*/extension.yml extensions/*/*/extension.yml; do
	[[ -f "${yml_path}" ]] || continue

	# Extract usage field (e.g., "owner/repo" or "owner/repo@v1.0")
	usage=$(grep -m1 '^[[:space:]]*usage:' "${yml_path}" | sed 's/^[[:space:]]*usage:[[:space:]]*//' | xargs)
	[[ -z "${usage}" ]] && continue

	# Strip @version to get the test-results.json key
	key="${usage%%@*}"

	# Check if this extension has test results
	results=$(jq -r --arg k "${key}" '.[$k].results // empty' "${RESULTS_FILE}")
	[[ -z "${results}" ]] && continue

	count=$(jq -r --arg k "${key}" '.[$k].results | length' "${RESULTS_FILE}")
	[[ "${count}" -eq 0 ]] && continue

	# Build YAML block and append
	{
		echo "  test-results:"
		jq -r --arg k "${key}" '
      .[$k].results[] |
      "    - quarto-version: \"" + .quarto_version + "\"\n" +
      "      quarto-channel: \"" + .quarto_channel + "\"\n" +
      "      status: \"" + .status + "\"\n" +
      "      log: \"" + .log + "\"\n" +
      "      date: \"" + .date + "\""
    ' "${RESULTS_FILE}"
	} >>"${yml_path}"
done
