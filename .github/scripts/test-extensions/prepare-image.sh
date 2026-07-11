#!/usr/bin/env bash
set -euo pipefail

# Prepare the local 'render-image' used by clone-extensions.sh and
# render-extensions.sh: pull the test image and apply a job-level overlay
# (TinyTeX ownership fix so tlmgr works when the container runs as host UID:GID).
# Inputs (env): IMAGE (digest-pinned ref, or a tag that gets resolved to one)
# Outputs: docker image tagged 'render-image'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry.sh
source "${SCRIPT_DIR}/retry.sh"

if ! retry 3 5 docker pull "${IMAGE}"; then
	echo "::error::Failed to pull image '${IMAGE}'."
	exit 1
fi

if [[ "${IMAGE}" =~ @sha256:[0-9a-f]{64}$ ]]; then
	image_ref="${IMAGE}"
else
	image_ref=$(docker image inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null || true)
	if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
		echo "::error::Failed to resolve a digest-pinned reference for image '${IMAGE}' (got '${image_ref}')."
		exit 1
	fi
fi

docker tag "${image_ref}" render-image

# Pick one reachable CTAN mirror per job instead of negotiating per extension.
CTAN_MIRRORS=(
	"https://ctan.math.utah.edu/ctan/tex-archive/systems/texlive/tlnet"
	"https://ctan.math.illinois.edu/systems/texlive/tlnet"
	"https://mirrors.rit.edu/CTAN/systems/texlive/tlnet"
	"https://mirror.ctan.org/systems/texlive/tlnet"
)
CTAN_MIRROR=""
for mirror in "${CTAN_MIRRORS[@]}"; do
	if retry 2 2 curl -fsI --max-time 10 "${mirror}/" >/dev/null 2>&1; then
		CTAN_MIRROR="${mirror}"
		break
	fi
	echo "CTAN mirror ${mirror} unreachable, trying next..."
done
if [[ -n "${CTAN_MIRROR}" ]]; then
	echo "Using CTAN mirror: ${CTAN_MIRROR}"
else
	echo "::warning::No CTAN mirror reachable. tlmgr keeps the repository baked into the image."
fi

# Job-level overlay: point tlmgr at the chosen mirror (as root, before the
# ownership change), then fix TinyTeX ownership so tlmgr works when the
# container runs as host UID:GID.
docker build -t render-image \
	--build-arg HOST_UID="$(id -u)" \
	--build-arg HOST_GID="$(id -g)" \
	--build-arg CTAN_MIRROR="${CTAN_MIRROR}" \
	- <<'OVERLAY'
FROM render-image
ARG HOST_UID
ARG HOST_GID
ARG CTAN_MIRROR
USER root
RUN if [ -d /opt/tinytex ] && [ -n "${CTAN_MIRROR}" ] && command -v tlmgr >/dev/null 2>&1; then \
    tlmgr repository set "${CTAN_MIRROR}" && tlmgr update --self; \
    fi
RUN if [ -d /opt/tinytex ]; then chown -R "${HOST_UID}:${HOST_GID}" /opt/tinytex; fi
OVERLAY

echo "Prepared render-image from ${image_ref}."
