#!/usr/bin/env bash
# Install the apohl79/cmux fork build. Prefer downloading the fork release zip;
# build/sign/notarize/upload it locally only when the release asset is missing,
# then refresh Codex and Claude Code session-restore hooks.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/install-fork.sh [options]

Downloads the fork release zip from apohl79/cmux and installs it. If the release
asset is unavailable, calls ./scripts/build-fork.sh to build/sign/notarize,
create the release if needed, upload the zip with --clobber, then installs it.
After installation, refreshes Codex hooks and validates the bundled Claude Code
wrapper used to inject current hooks into new sessions.

Options:
  --target <path>           Install path (default: /Applications/cmux.app).
  --repo <owner/repo>       GitHub repo for the fork release (default: apohl79/cmux).
  --version <version>       Release version (default: <MARKETING_VERSION>-apohl79).
  --tag <tag>               GitHub release tag (default: release version).
  --asset-name <name>       Release asset name (default: cmux-<version>-macos.zip).
  --download-dir <path>     Download/build artifact dir (default: build/fork-downloads).
  --force-build             Skip download and call build-fork.sh immediately.

Build fallback options passed through to build-fork.sh:
  --skip-build
  --skip-deps
  --source <path>
  --arch <arm64|x86_64>
  --sign <identity>
  --adhoc
  --notarize
  --skip-notarize
  --notary-profile <name>

Environment:
  NOTARIZE=1 APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=...
  NOTARYTOOL_PROFILE=cmux-notary ./scripts/install-fork.sh
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-cmux}"
TARGET="${TARGET:-/Applications/${APP_NAME}.app}"
FORK_REPO="${FORK_REPO:-apohl79/cmux}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PROJECT_DIR/build/fork-downloads}"
VERSION_OVERRIDE="${VERSION:-}"
TAG_OVERRIDE="${TAG:-}"
ASSET_NAME_OVERRIDE="${ASSET_NAME:-}"
FORCE_BUILD=0
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --repo) FORK_REPO="$2"; shift 2 ;;
    --version) VERSION_OVERRIDE="$2"; shift 2 ;;
    --tag) TAG_OVERRIDE="$2"; shift 2 ;;
    --asset-name) ASSET_NAME_OVERRIDE="$2"; shift 2 ;;
    --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
    --force-build) FORCE_BUILD=1; shift ;;
    --skip-build|--skip-deps|--adhoc|--notarize|--skip-notarize)
      BUILD_ARGS+=("$1")
      shift
      ;;
    --source|--arch|--sign|--notary-profile)
      BUILD_ARGS+=("$1" "$2")
      shift 2
      ;;
    --debug)
      echo "error: install-fork installs release assets only; Debug installs are not fork releases." >&2
      exit 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }

PROJECT_FILE="$PROJECT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"
OFFICIAL_VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')"
if [[ -z "$OFFICIAL_VERSION" ]]; then
  echo "error: could not determine MARKETING_VERSION from $PROJECT_FILE" >&2
  exit 1
fi

VERSION="${VERSION_OVERRIDE:-${OFFICIAL_VERSION}-apohl79}"
TAG="${TAG_OVERRIDE:-$VERSION}"
ASSET_NAME="${ASSET_NAME_OVERRIDE:-cmux-${VERSION}-macos.zip}"

mkdir -p "$DOWNLOAD_DIR"
DOWNLOAD_DIR="$(cd "$DOWNLOAD_DIR" && pwd)"
ZIP_PATH="$DOWNLOAD_DIR/$ASSET_NAME"

download_release_asset() {
  if [[ "$FORCE_BUILD" == "1" ]]; then
    log "download skipped (--force-build)"
    return 1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    log "gh not found; building fork release locally"
    return 1
  fi

  if ! gh release view "$TAG" --repo "$FORK_REPO" >/dev/null 2>&1; then
    log "release not found: $FORK_REPO@$TAG"
    return 1
  fi

  rm -f "$ZIP_PATH"
  log "downloading $ASSET_NAME from $FORK_REPO@$TAG"
  if gh release download "$TAG" --repo "$FORK_REPO" --pattern "$ASSET_NAME" --dir "$DOWNLOAD_DIR" >/tmp/install-fork-download.log 2>&1; then
    if [[ -f "$ZIP_PATH" ]]; then
      return 0
    fi
  fi

  log "release asset unavailable; build fallback required"
  if [[ -s /tmp/install-fork-download.log ]]; then
    tail -20 /tmp/install-fork-download.log >&2 || true
  fi
  return 1
}

build_release_asset() {
  local build_cmd

  build_cmd=(
    "$SCRIPT_DIR/build-fork.sh"
    --repo "$FORK_REPO"
    --version "$VERSION"
    --tag "$TAG"
    --asset-name "$ASSET_NAME"
    --output-dir "$DOWNLOAD_DIR"
  )
  build_cmd+=("${BUILD_ARGS[@]}")

  log "building fork release asset via build-fork.sh"
  "${build_cmd[@]}"

  if [[ ! -f "$ZIP_PATH" ]]; then
    echo "error: build-fork.sh did not produce expected asset: $ZIP_PATH" >&2
    exit 1
  fi
}

if ! download_release_asset; then
  build_release_asset
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: release zip not found at $ZIP_PATH" >&2
  exit 1
fi

UNPACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-fork-install.XXXXXX")"
cleanup() {
  rm -rf "$UNPACK_DIR"
}
trap cleanup EXIT

log "extracting $ZIP_PATH"
ditto -x -k "$ZIP_PATH" "$UNPACK_DIR"

SOURCE_APP="$(find "$UNPACK_DIR" -maxdepth 2 -name "*.app" -type d | sort | head -n 1 || true)"
if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  echo "error: no .app bundle found in $ZIP_PATH" >&2
  exit 1
fi

needs_sudo=0
target_dir="$(dirname "$TARGET")"
if [[ ! -w "$target_dir" ]]; then
  needs_sudo=1
fi

if [[ "$needs_sudo" == "1" ]]; then
  log "installing to $TARGET (requires sudo for $target_dir)"
  sudo rm -rf "$TARGET"
  sudo ditto "$SOURCE_APP" "$TARGET"
  sudo chown -R "$(id -u):$(id -g)" "$TARGET"
else
  log "installing to $TARGET"
  rm -rf "$TARGET"
  ditto "$SOURCE_APP" "$TARGET"
fi

log "removing com.apple.quarantine attribute"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Contents/Info.plist" 2>/dev/null || echo cmux)"
binary="$TARGET/Contents/MacOS/$bundle_executable"
if [[ ! -x "$binary" ]]; then
  echo "error: installed binary is not executable: $binary" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
  echo "warning: codesign verification failed for installed app: $TARGET" >&2
fi

bundled_cli="$TARGET/Contents/Resources/bin/cmux"
claude_wrapper="$TARGET/Contents/Resources/bin/claude"

if [[ ! -x "$bundled_cli" ]]; then
  echo "error: bundled cmux CLI is not executable: $bundled_cli" >&2
  exit 1
fi
if [[ ! -x "$claude_wrapper" ]]; then
  echo "error: bundled Claude Code wrapper is not executable: $claude_wrapper" >&2
  exit 1
fi

log "installing or updating Codex session-restore hooks"
"$bundled_cli" hooks codex install --yes
log "Claude Code session-restore hooks updated via bundled wrapper"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"

log "installed:"
echo "  path:            $TARGET"
echo "  bundle id:       $bundle_id"
echo "  app version:     $short_version ($build_version)"
echo "  release version: $VERSION"
echo "  release tag:     $TAG"
echo "  asset:           $ASSET_NAME"
echo
log "to launch:"
echo "  open \"$TARGET\""
