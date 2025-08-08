#!/usr/bin/env bash

if [ -z "${QUARTO_PROJECT_RENDER_ALL}" ]; then
  exit 0
fi

set -e

git fetch origin quarto-wizard:quarto-wizard
git restore --source=quarto-wizard --worktree "extensions"

echo -e "extensions: $(find extensions -name "extension.json" | wc -l | tr -d ' ')" > _variables.yml
