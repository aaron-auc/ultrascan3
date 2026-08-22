#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 CACHE_KEY_PREFIX [CACHE_KEY_PREFIX ...]" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

for prefix in "$@"; do
  echo "Deleting caches matching: ${prefix}"

  cache_json=$(gh cache list --repo "$GITHUB_REPOSITORY" --key "$prefix" \
    --limit 100 --json id,key)
  cache_ids=$(jq -r --arg prefix "$prefix" \
    '.[] | select(.key | startswith($prefix)) | .id' \
    <<< "$cache_json")

  if [[ -z "$cache_ids" ]]; then
    echo "  No matching caches found."
    continue
  fi

  while IFS= read -r cache_id; do
    echo "  Deleting cache ID ${cache_id}"
    gh cache delete "$cache_id" --repo "$GITHUB_REPOSITORY"
  done <<< "$cache_ids"
done
