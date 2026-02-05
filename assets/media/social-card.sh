#!/usr/bin/env bash

npx playwright screenshot \
  --viewport-size="1200,630" \
  --wait-for-timeout=3000 \
  _social-card.html social-card.png
