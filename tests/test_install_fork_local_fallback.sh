#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-install-fallback-test.XXXXXX")"
FIXTURE_PROJECT="$TEST_DIR/project"
MOCK_BIN="$TEST_DIR/bin"
FAKE_APP="$TEST_DIR/cmux.app"
TARGET_APP="$TEST_DIR/installed/cmux.app"
mkdir -p \
  "$FIXTURE_PROJECT/scripts" \
  "$FIXTURE_PROJECT/GhosttyTabs.xcodeproj" \
  "$MOCK_BIN" \
  "$FAKE_APP/Contents/MacOS" \
  "$FAKE_APP/Contents/Resources/bin" \
  "$(dirname "$TARGET_APP")"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$PROJECT_DIR/scripts/install-fork.sh" "$FIXTURE_PROJECT/scripts/install-fork.sh"
cp "$PROJECT_DIR/scripts/apohl79_build_number.txt" "$FIXTURE_PROJECT/scripts/apohl79_build_number.txt"
printf 'MARKETING_VERSION = 0.64.5;\n' \
  >"$FIXTURE_PROJECT/GhosttyTabs.xcodeproj/project.pbxproj"

cat >"$FIXTURE_PROJECT/scripts/build-fork.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_dir=""
asset_name=""
no_upload=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    --asset-name) asset_name="$2"; shift 2 ;;
    --repo|--version|--tag) shift 2 ;;
    --no-upload) no_upload=1; shift ;;
    *) shift ;;
  esac
done

if [[ "$no_upload" != "1" ]]; then
  echo "build fallback attempted to publish a release asset" >&2
  exit 42
fi
if [[ "$asset_name" != "cmux-0.64.5-apohl79-build-86-macos.zip" ]]; then
  echo "unexpected build-number asset name: $asset_name" >&2
  exit 43
fi

mkdir -p "$output_dir"
: >"$output_dir/$asset_name"
EOF
chmod +x "$FIXTURE_PROJECT/scripts/build-fork.sh"

cat >"$MOCK_BIN/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-x" ]]; then
  mkdir -p "$4/cmux.app"
  cp -R "$FAKE_APP/Contents" "$4/cmux.app/Contents"
else
  mkdir -p "$2"
  cp -R "$1/Contents" "$2/Contents"
fi
EOF

cat >"$MOCK_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/xattr" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/plistbuddy" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  *CFBundleExecutable*) echo cmux ;;
  *CFBundleIdentifier*) echo com.cmuxterm.app ;;
  *CFBundleShortVersionString*) echo 0.64.5 ;;
  *CFBundleVersion*) echo 64 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$MOCK_BIN"/*

cat >"$FAKE_APP/Contents/MacOS/cmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_APP/Contents/Resources/bin/cmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_APP/Contents/Resources/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \
  "$FAKE_APP/Contents/MacOS/cmux" \
  "$FAKE_APP/Contents/Resources/bin/cmux" \
  "$FAKE_APP/Contents/Resources/bin/claude"

FAKE_APP="$FAKE_APP" \
PATH="$MOCK_BIN:$PATH" \
PLISTBUDDY="$MOCK_BIN/plistbuddy" \
"$FIXTURE_PROJECT/scripts/install-fork.sh" \
  --force-build \
  --target "$TARGET_APP" \
  --download-dir "$TEST_DIR/downloads"

[[ -x "$TARGET_APP/Contents/MacOS/cmux" ]] ||
  { echo "FAIL: local build fallback did not install the app" >&2; exit 1; }

echo "PASS: local build fallback installs without depending on release publication"
