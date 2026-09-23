#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PROJECT_DIR/scripts/replace-fork-release-asset.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-release-asset-test.XXXXXX")"
MOCK_BIN="$TEST_DIR/bin"
CALL_LOG="$TEST_DIR/gh-calls.log"
mkdir -p "$MOCK_BIN"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_CALL_LOG"

if [[ "$1" == "api" && "$2" == *"/releases/tags/"* ]]; then
  if [[ "${GH_ASSET_MODE:-duplicates}" == "eventual" ]]; then
    asset_view_count="$(grep -c '/releases/tags/' "$GH_CALL_LOG")"
    if [[ "$asset_view_count" -ge 3 ]]; then
      printf '%s\n' $'583459102\tcmux-test-macos.zip'
    fi
    exit 0
  fi

  if [[ "${GH_ASSET_MODE:-duplicates}" == "unrelated" ]]; then
    printf '%s\n' \
      $'544133625\tcmux-test-macos.zip' \
      $'544133999\tchecksums.txt'
    exit 0
  fi

  if [[ "${GH_ASSET_MODE:-duplicates}" == "accessible" ]]; then
    printf '%s\n' $'544133627\tcmux-test-macos.zip'
    exit 0
  fi

  printf '%s\n' \
    $'544133625\tcmux-test-macos.zip' \
    $'544133626\tcmux-test-macos.zip' \
    $'544133627\tcmux-test-macos.zip'
  exit 0
fi

if [[ "$1" == "api" && "$2" == *"/releases/assets/"* ]]; then
  case "$2" in
    *544133625)
      printf '%s\n' \
        '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/assets#get-a-release-asset","status":"404"}' \
        'gh: Not Found (HTTP 404)' >&2
      exit 1
      ;;
    *544133626)
      echo 'HTTP 404: Not Found (https://api.github.com/repos/apohl79/cmux/releases/assets/544133626)' >&2
      exit 1
      ;;
    *544133627)
      if [[ "${GH_PROBE_MODE:-success}" == "forbidden" ]]; then
        echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
        exit 1
      fi
      exit 0
      ;;
    *583459102)
      exit 0
      ;;
  esac
fi

if [[ "$1" == "api" && "$2" == "--method" ]]; then
  if [[ "${GH_DELETE_MODE:-success}" == "forbidden" ]]; then
    echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
    exit 1
  fi
  exit 0
fi

if [[ "$1" == "release" && "$2" == "upload" ]]; then
  if [[ "${GH_UPLOAD_MODE:-success}" == "already_exists" ]]; then
    echo 'HTTP 422: Validation Failed (https://api.github.com/repos/apohl79/cmux/releases/394506541/assets)' >&2
    echo 'ReleaseAsset.name already exists' >&2
    exit 1
  fi
  exit 0
fi

if [[ "$1" == "release" && "$2" == "delete" ]]; then
  exit 0
fi

if [[ "$1" == "release" && "$2" == "create" ]]; then
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$MOCK_BIN/gh"

export GH_CALL_LOG="$CALL_LOG"
export PATH="$MOCK_BIN:$PATH"
export RELEASE_ASSET_VISIBILITY_ATTEMPTS=3
export RELEASE_ASSET_VISIBILITY_DELAY_SECONDS=0

asset_path="$TEST_DIR/cmux-test-macos.zip"
: >"$asset_path"

"$HELPER" \
  apohl79/cmux \
  test-tag \
  "$asset_path" \
  cmux-test-macos.zip \
  test-title \
  test-notes

grep -Fq 'releases/assets/544133625' "$CALL_LOG" ||
  fail "did not attempt the JSON-status 404 asset"
grep -Fq 'releases/assets/544133626' "$CALL_LOG" ||
  fail "did not attempt the legacy-text 404 asset"
grep -Fq 'release delete test-tag --repo apohl79/cmux --yes' "$CALL_LOG" ||
  fail "did not recreate the release after encountering a zombie asset"
grep -Fq 'release create test-tag --repo apohl79/cmux --title test-title --notes test-notes' "$CALL_LOG" ||
  fail "did not restore the release metadata"
grep -Fq "release upload test-tag $asset_path --repo apohl79/cmux" "$CALL_LOG" ||
  fail "did not upload the replacement asset"
if grep -Fq -- '--clobber' "$CALL_LOG"; then
  fail "replacement upload unexpectedly used --clobber"
fi

: >"$CALL_LOG"
export GH_ASSET_MODE=accessible
export GH_DELETE_MODE=forbidden

if "$HELPER" \
  apohl79/cmux \
  test-tag \
  "$asset_path" \
  cmux-test-macos.zip \
  test-title \
  test-notes; then
  fail "non-404 deletion failure unexpectedly succeeded"
fi

if grep -Fq 'release upload' "$CALL_LOG"; then
  fail "uploaded after a non-404 deletion failure"
fi

: >"$CALL_LOG"
unset GH_DELETE_MODE
export GH_ASSET_MODE=accessible

"$HELPER" \
  apohl79/cmux \
  test-tag \
  "$asset_path" \
  cmux-test-macos.zip \
  test-title \
  test-notes

grep -Fq 'api --method DELETE repos/apohl79/cmux/releases/assets/544133627' "$CALL_LOG" ||
  fail "did not delete an accessible matching asset"
if grep -Eq 'release (delete|create)' "$CALL_LOG"; then
  fail "recreated a release whose matching assets were accessible"
fi

: >"$CALL_LOG"
export GH_ASSET_MODE=unrelated

if "$HELPER" \
  apohl79/cmux \
  test-tag \
  "$asset_path" \
  cmux-test-macos.zip \
  test-title \
  test-notes; then
  fail "zombie asset recovery deleted a release containing unrelated assets"
fi

if grep -Eq 'release (delete|create|upload)' "$CALL_LOG"; then
  fail "mutated a release containing unrelated assets"
fi

: >"$CALL_LOG"
export GH_ASSET_MODE=eventual
export GH_UPLOAD_MODE=already_exists

"$HELPER" \
  apohl79/cmux \
  test-tag \
  "$asset_path" \
  cmux-test-macos.zip \
  test-title \
  test-notes

[[ "$(grep -c 'release upload' "$CALL_LOG")" -eq 1 ]] ||
  fail "did not make exactly one upload attempt during eventual consistency"
[[ "$(grep -c '/releases/tags/' "$CALL_LOG")" -ge 3 ]] ||
  fail "did not poll until the uploaded asset became visible"

echo "PASS: fork release asset replacement repairs zombie assets without risking unrelated assets"
