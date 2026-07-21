#!/usr/bin/env bash
set -euo pipefail

# Decide whether the test image needs a rebuild by comparing the Dockerfile
# hash and the base image digest against labels stored on the published image.
# Missing image or unreadable labels fall back to a rebuild.
# Inputs (env): BASE_IMAGE, TARGET_IMAGE, GITHUB_OUTPUT
# Inputs (env, optional): FORCE (default false)
# Outputs (GITHUB_OUTPUT): build (true/false), dockerfile-sha, base-digest

BASE_IMAGE="${BASE_IMAGE:?BASE_IMAGE is required (e.g. ghcr.io/<owner>/quarto-codespaces:release)}"
TARGET_IMAGE="${TARGET_IMAGE:?TARGET_IMAGE is required (e.g. ghcr.io/<owner>/<repo>:release)}"
FORCE="${FORCE:-false}"

dockerfile_sha=$(sha256sum .github/docker/test-extensions/Dockerfile | cut -d' ' -f1)
base_digest=$(docker buildx imagetools inspect "${BASE_IMAGE}" --format '{{.Manifest.Digest}}')
{
	echo "dockerfile-sha=${dockerfile_sha}"
	echo "base-digest=${base_digest}"
} >>"${GITHUB_OUTPUT}"

if [[ "${FORCE}" == "true" ]]; then
	echo "::notice::Force rebuild requested for '${TARGET_IMAGE}'."
	echo "build=true" >>"${GITHUB_OUTPUT}"
	exit 0
fi

labels=$(docker buildx imagetools inspect "${TARGET_IMAGE}" \
	--format '{{json .Image.Config.Labels}}' 2>/dev/null || echo '{}')
stored_sha=$(jq -r '."io.quarto-extensions.dockerfile-sha256" // empty' <<<"${labels}")
stored_base=$(jq -r '."org.opencontainers.image.base.digest" // empty' <<<"${labels}")

if [[ "${stored_sha}" == "${dockerfile_sha}" && "${stored_base}" == "${base_digest}" ]]; then
	echo "::notice::'${TARGET_IMAGE}' is up to date (Dockerfile and base image unchanged). Skipping build."
	echo "build=false" >>"${GITHUB_OUTPUT}"
else
	echo "::notice::'${TARGET_IMAGE}' needs a rebuild (Dockerfile or base image changed, or labels missing)."
	echo "build=true" >>"${GITHUB_OUTPUT}"
fi
