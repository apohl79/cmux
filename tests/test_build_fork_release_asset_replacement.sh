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

if [[ "$1" == "api" && "$2" != "--method" ]]; then
  printf '%s\n' \
    $'544133625\tcmux-test-macos.zip' \
    $'544133626\tcmux-test-macos.zip' \
    $'544133627\tcmux-test-macos.zip'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "--method" ]]; then
  case "$4" in
    *544133625)
      printf '%s\n' \
        '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/assets#delete-a-release-asset","status":"404"}' \
        'gh: Not Found (HTTP 404)' >&2
      exit 1
      ;;
    *544133626)
      echo 'HTTP 404: Not Found (https://api.github.com/repos/apohl79/cmux/releases/assets/544133626)' >&2
      exit 1
      ;;
    *544133627)
      if [[ "${GH_DELETE_MODE:-success}" == "forbidden" ]]; then
        echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2
        exit 1
      fi
      exit 0
      ;;
  esac
fi

if [[ "$1" == "release" && "$2" == "upload" ]]; then
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$MOCK_BIN/gh"

export GH_CALL_LOG="$CALL_LOG"
export PATH="$MOCK_BIN:$PATH"

asset_path="$TEST_DIR/cmux-test-macos.zip"
: >"$asset_path"

"$HELPER" apohl79/cmux test-tag "$asset_path" cmux-test-macos.zip

grep -Fq 'releases/assets/544133625' "$CALL_LOG" ||
  fail "did not attempt the JSON-status 404 asset"
grep -Fq 'releases/assets/544133626' "$CALL_LOG" ||
  fail "did not attempt the legacy-text 404 asset"
grep -Fq 'releases/assets/544133627' "$CALL_LOG" ||
  fail "did not delete the live duplicate asset"
grep -Fq "release upload test-tag $asset_path --repo apohl79/cmux" "$CALL_LOG" ||
  fail "did not upload the replacement asset"
if grep -Fq -- '--clobber' "$CALL_LOG"; then
  fail "replacement upload unexpectedly used --clobber"
fi

: >"$CALL_LOG"
export GH_DELETE_MODE=forbidden

if "$HELPER" apohl79/cmux test-tag "$asset_path" cmux-test-macos.zip; then
  fail "non-404 deletion failure unexpectedly succeeded"
fi

if grep -Fq 'release upload' "$CALL_LOG"; then
  fail "uploaded after a non-404 deletion failure"
fi

echo "PASS: fork release asset replacement handles stale 404s and preserves other errors"
