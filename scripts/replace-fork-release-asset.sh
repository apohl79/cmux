#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: replace-fork-release-asset.sh <repo> <tag> <asset-path> <asset-name>

Removes every release asset with the requested name, tolerating stale asset
IDs that GitHub reports as already absent, then uploads the replacement.
EOF
}

if [[ $# -ne 4 ]]; then
  usage >&2
  exit 2
fi

FORK_REPO="$1"
TAG="$2"
ASSET_PATH="$3"
ASSET_NAME="$4"

log() { printf '==> %s\n' "$*"; }

is_http_404() {
  printf '%s\n' "$1" |
    grep -Eq 'HTTP 404|"status"[[:space:]]*:[[:space:]]*"?404"?'
}

release_assets=""
if ! release_assets="$(gh api "repos/$FORK_REPO/releases/tags/$TAG" \
  --jq '.assets[] | [.id, .name] | @tsv' 2>&1)"; then
  printf '%s\n' "$release_assets" >&2
  exit 1
fi

while IFS=$'\t' read -r asset_id asset_name; do
  [[ "$asset_id" =~ ^[0-9]+$ && "$asset_name" == "$ASSET_NAME" ]] || continue

  log "removing existing release asset $ASSET_NAME (id: $asset_id)"
  delete_output=""
  if delete_output="$(gh api --method DELETE \
    "repos/$FORK_REPO/releases/assets/$asset_id" 2>&1)"; then
    continue
  else
    delete_status=$?
  fi

  if is_http_404 "$delete_output"; then
    log "release asset id $asset_id is already absent; continuing"
    continue
  fi

  printf '%s\n' "$delete_output" >&2
  exit "$delete_status"
done <<<"$release_assets"

log "uploading $ASSET_NAME"
gh release upload "$TAG" "$ASSET_PATH" --repo "$FORK_REPO"
