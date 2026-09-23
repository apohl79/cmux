#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: replace-fork-release-asset.sh <repo> <tag> <asset-path> <asset-name> <title> <notes>

Removes every release asset with the requested name, tolerating stale asset
IDs that GitHub reports as already absent, then uploads the replacement.
EOF
}

if [[ $# -ne 6 ]]; then
  usage >&2
  exit 2
fi

FORK_REPO="$1"
TAG="$2"
ASSET_PATH="$3"
ASSET_NAME="$4"
RELEASE_TITLE="$5"
RELEASE_NOTES="$6"
: "$RELEASE_TITLE" "$RELEASE_NOTES"

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

unrelated_asset_count=0
while IFS=$'\t' read -r asset_id asset_name; do
  [[ "$asset_id" =~ ^[0-9]+$ ]] || continue
  if [[ "$asset_name" != "$ASSET_NAME" ]]; then
    unrelated_asset_count=$((unrelated_asset_count + 1))
  fi
done <<<"$release_assets"

accessible_asset_ids=""
zombie_asset_detected=0
while IFS=$'\t' read -r asset_id asset_name; do
  [[ "$asset_id" =~ ^[0-9]+$ && "$asset_name" == "$ASSET_NAME" ]] || continue

  probe_output=""
  if probe_output="$(gh api \
    "repos/$FORK_REPO/releases/assets/$asset_id" 2>&1)"; then
    accessible_asset_ids="${accessible_asset_ids}${asset_id}"$'\n'
    continue
  else
    probe_status=$?
  fi

  if is_http_404 "$probe_output"; then
    zombie_asset_detected=1
    continue
  fi

  printf '%s\n' "$probe_output" >&2
  exit "$probe_status"
done <<<"$release_assets"

if [[ "$zombie_asset_detected" == "1" ]]; then
  if [[ "$unrelated_asset_count" -gt 0 ]]; then
    echo "error: refusing to recreate $FORK_REPO@$TAG because it contains unrelated release assets" >&2
    exit 1
  fi

  log "recreating release $FORK_REPO@$TAG to remove inaccessible asset records"
  gh release delete "$TAG" --repo "$FORK_REPO" --yes
  gh release create "$TAG" \
    --repo "$FORK_REPO" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"
else
  while IFS= read -r asset_id; do
    [[ "$asset_id" =~ ^[0-9]+$ ]] || continue
    log "removing existing release asset $ASSET_NAME (id: $asset_id)"
    gh api --method DELETE \
      "repos/$FORK_REPO/releases/assets/$asset_id" >/dev/null
  done <<<"$accessible_asset_ids"
fi

log "uploading $ASSET_NAME"
gh release upload "$TAG" "$ASSET_PATH" --repo "$FORK_REPO"
