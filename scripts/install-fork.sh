#!/usr/bin/env bash
# Build a Release cmux.app from the current worktree and install it as
# /Applications/cmux-fork.app (or a custom path).
#
# Usage:
#   ./scripts/install-fork.sh                # build + install to /Applications/cmux-fork.app
#   ./scripts/install-fork.sh --skip-build   # use the pre-built artifact in build/release
#   ./scripts/install-fork.sh --target ~/Applications/cmux-fork.app
#   APP_NAME=cmux-foo ./scripts/install-fork.sh
#
# Requirements:
#   - Xcode 26.x with Metal Toolchain
#   - zig 0.15.x on PATH (or at /opt/homebrew/opt/zig@0.15/bin)
#   - sudo access if installing under /Applications
#
# What it does:
#   1. (Unless --skip-build) Builds Release arm64 cmux.app via xcodebuild,
#      with CODE_SIGNING_ALLOWED=NO. Output: build/release/Build/Products/Release/cmux.app
#   2. Removes any existing app at the target path.
#   3. Copies the build artifact with ditto (preserving extended attributes,
#      symlinks, and HFS metadata).
#   4. Chowns the installed app to the invoking user.
#   5. Ad-hoc codesigns the bundle so macOS will launch it without a developer cert.
#   6. Strips the com.apple.quarantine xattr so first launch isn't blocked.
#   7. Verifies the installed binary is executable and reports the bundle id + path.
#
# Note: ad-hoc signing is only safe for a personal/local fork. Don't redistribute
# the resulting app — it has no Developer ID signature and won't pass Gatekeeper
# on other Macs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-cmux-fork}"
TARGET="/Applications/${APP_NAME}.app"
SKIP_BUILD=0
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/release}"
SOURCE_APP="${SOURCE_APP:-$DERIVED_DATA/Build/Products/Release/cmux.app}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --source) SOURCE_APP="$2"; shift 2 ;;
    -h|--help)
      awk '/^set -euo pipefail/{exit} /^#!/{next} /^#( |$)/{sub(/^# ?/, ""); print}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }

# ---------- Prerequisites -----------------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found. Install Xcode." >&2
    exit 1
  fi
  if ! command -v zig >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/opt/zig@0.15/bin/zig ]]; then
      export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
      log "using zig at /opt/homebrew/opt/zig@0.15/bin"
    else
      echo "error: zig 0.15.x not found on PATH and not at /opt/homebrew/opt/zig@0.15/bin." >&2
      echo "       brew install zig@0.15" >&2
      exit 1
    fi
  fi
  zig_version="$(zig version 2>/dev/null || true)"
  if [[ "$zig_version" != 0.15.* ]]; then
    echo "error: zig version mismatch (have $zig_version, need 0.15.x)." >&2
    exit 1
  fi
fi

# ---------- Build (unless skipped) -------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  log "building Release (arm64) into $DERIVED_DATA"
  xcodebuild \
    -project GhosttyTabs.xcodeproj \
    -scheme cmux \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS,arch=arm64' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    build >/tmp/install-fork-build.log 2>&1 || {
      echo "error: build failed. tail of /tmp/install-fork-build.log:" >&2
      tail -30 /tmp/install-fork-build.log >&2
      exit 1
    }
  log "build succeeded"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: source app not found at $SOURCE_APP" >&2
  echo "       run without --skip-build, or pass --source <path>" >&2
  exit 1
fi

# ---------- Install ----------------------------------------------------------
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

# ---------- Sign + unquarantine ---------------------------------------------
log "ad-hoc codesigning $TARGET"
codesign --force --deep --sign - "$TARGET" >/dev/null 2>&1 || {
  echo "warning: codesign failed; the app may not launch on a hardened-runtime system" >&2
}

log "removing com.apple.quarantine attribute"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# ---------- Verify -----------------------------------------------------------
binary="$TARGET/Contents/MacOS/cmux"
if [[ ! -x "$binary" ]]; then
  echo "error: installed binary is not executable: $binary" >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"

log "installed:"
echo "  path:       $TARGET"
echo "  bundle id:  $bundle_id"
echo "  version:    $short_version ($build_version)"
echo
log "to launch:"
echo "  open \"$TARGET\""
