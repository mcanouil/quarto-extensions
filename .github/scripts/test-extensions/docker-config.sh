#!/usr/bin/env bash
# Shared Docker configuration for test-extensions scripts.
# Source this file; do not execute it directly.

DOCKER_USER="$(id -u):$(id -g)"
DOCKER_SECURITY_OPTS=(
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=512
  --memory=4g
  --cpus=2
  --read-only
  --tmpfs /tmp:rw,nosuid,size=512m
  --tmpfs /var/tmp:rw,noexec,nosuid,size=128m
)
