#!/usr/bin/env bash
set -euo pipefail

# Fetch one of the data branches that the render reads from.
#
# Only the branch tip is ever read, and these branches carry thousands of
# image-heavy commits, so CI fetches at depth 1. A developer's full clone must
# not be truncated into a shallow one, so the depth is applied only under CI.
#
# `--force` keeps this idempotent: without it the fetch is rejected as
# non-fast-forward as soon as the branch exists locally, which is every run
# after the first.
#
# Arguments:
#   $1 - Branch name

branch="${1:?branch name required}"

args=(fetch --force origin "${branch}:${branch}")
if [[ -n "${CI:-}" ]]; then
  args=(fetch --depth=1 --force origin "${branch}:${branch}")
fi

git "${args[@]}"
