#!/usr/bin/env bash
# Build a Release cmux.app from the current worktree and install it as
# /Applications/cmux.app (or a custom path).
#
# Usage:
#   ./scripts/install-fork.sh                # build + install to /Applications/cmux.app
#   ./scripts/install-fork.sh --skip-build   # use the pre-built artifact in build/release
#   ./scripts/install-fork.sh --skip-deps    # skip Homebrew/submodule preflight
#   ./scripts/install-fork.sh --target ~/Applications/cmux.app
#   ./scripts/install-fork.sh --arch x86_64  # override host arch detection (default: uname -m)
#   ./scripts/install-fork.sh --debug        # build Debug instead of Release, install to /Applications/cmux-debug.app
#   ./scripts/install-fork.sh --sign "Developer ID Application: Name (TEAMID)"  # sign with a specific identity
#   ./scripts/install-fork.sh --adhoc        # force ad-hoc signing even if a Developer ID cert exists
#   ./scripts/install-fork.sh --notarize    # require notarization after Developer ID signing
#   ./scripts/install-fork.sh --skip-notarize  # disable auto notarization
#   ./scripts/install-fork.sh --notary-profile cmux-notary  # use a notarytool keychain profile
#   NOTARIZE=1 APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... ./scripts/install-fork.sh
#   APP_NAME=cmux-foo ./scripts/install-fork.sh
#
# Requirements:
#   - macOS with Homebrew installed (brew on PATH)
#   - Xcode 26.x with Metal Toolchain
#   - sudo access if installing under /Applications
#   - For notarization: Developer ID signing plus --notary-profile or
#     APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD
#
# What it does:
#   1. Ensures Homebrew dependencies are installed (zig@0.15) and the
#      vendor/bonsplit git submodule is initialized + up to date.
#   2. (Unless --skip-build) Builds Release cmux.app via xcodebuild for the
#      host architecture (arm64 on Apple Silicon, x86_64 on Intel; override
#      with --arch), with CODE_SIGNING_ALLOWED=NO.
#      Output: build/release/Build/Products/Release/cmux.app
#   3. Removes any existing app at the target path.
#   4. Copies the build artifact with ditto (preserving extended attributes,
#      symlinks, and HFS metadata).
#   5. Chowns the installed app to the invoking user.
#   6. Strips com.apple.FinderInfo / resource forks (codesign rejects them).
#   7. Codesigns helper executables, then nested bundles (Frameworks/, PlugIns/),
#      then the outer bundle, so the resource manifest stays valid. Uses a
#      Developer ID Application identity if one is in the keychain (a stable
#      identity macOS TCC/Gatekeeper key on, so the "access data from other apps"
#      prompt and other per-app grants persist across reinstalls); falls back
#      to ad-hoc.
#   8. Notarizes and staples the app when Developer ID signing and notary
#      credentials are available, or when --notarize / NOTARIZE=1 requires it.
#   9. Strips the com.apple.quarantine xattr so first launch isn't blocked.
#  10. Verifies the installed binary is executable and reports the bundle id + path.
#
# Note: ad-hoc signing (no Developer ID cert / --adhoc) is only safe for a
# personal/local fork and cannot be notarized. A Developer ID signature is
# notarized when notary credentials are present in auto mode or required with
# --notarize.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-cmux}"
TARGET=""
SKIP_BUILD=0
SKIP_DEPS=0
DEBUG_BUILD=0
DERIVED_DATA=""
SOURCE_APP="${SOURCE_APP:-}"
ARCH="${ARCH:-$(uname -m)}"
DEBUG_BUNDLE_ID_SUFFIX="installed"

# Code signing identity for the installed app. Empty = auto-detect a
# "Developer ID Application" cert from the keychain (falls back to ad-hoc "-").
# Override with --sign "<identity>" / SIGN_IDENTITY=..., or force ad-hoc via --adhoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
FORCE_ADHOC=0
NOTARIZE="${NOTARIZE:-auto}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"

# Homebrew formulae the build needs at exact versions.
BREW_FORMULAE=(zig@0.15)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --debug) DEBUG_BUILD=1; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --source) SOURCE_APP="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --notarize) NOTARIZE=required; shift ;;
    --skip-notarize) NOTARIZE=never; shift ;;
    --notary-profile) NOTARYTOOL_PROFILE="$2"; shift 2 ;;
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

case "$NOTARIZE" in
  auto|required|never) ;;
  1|true|TRUE|yes|YES|always) NOTARIZE=required ;;
  0|false|FALSE|no|NO|off) NOTARIZE=never ;;
  *)
    echo "error: unsupported NOTARIZE value '$NOTARIZE' (expected auto, 1, or 0)" >&2
    exit 2
    ;;
esac

if [[ "$DEBUG_BUILD" == "1" ]]; then
  CONFIGURATION="Debug"
  DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/debug}"
  # Build under a distinct bundle id so the installed Debug app:
  #   - doesn't collide with developer reload.sh tagged builds, and
  #   - bypasses cmuxApp.shouldBlockUntaggedDebugLaunch (which only fires
  #     when the bundle id is exactly com.cmuxterm.app.debug).
  DEBUG_BUNDLE_ID="com.cmuxterm.app.debug.${DEBUG_BUNDLE_ID_SUFFIX}"
  # Don't override PRODUCT_NAME globally — xcodebuild applies it to every
  # target (PostHog_PostHog.bundle, swift-crypto_Crypto.bundle, …) and the
  # resulting name collision fails the build with "duplicate output file".
  # Keep the scheme's default "cmux DEV" product name and rename only at
  # install time via the TARGET path.
  SOURCE_APP="${SOURCE_APP:-$DERIVED_DATA/Build/Products/Debug/cmux DEV.app}"
  TARGET="${TARGET:-/Applications/cmux-debug.app}"
else
  CONFIGURATION="Release"
  DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/release}"
  SOURCE_APP="${SOURCE_APP:-$DERIVED_DATA/Build/Products/Release/cmux.app}"
  TARGET="${TARGET:-/Applications/${APP_NAME}.app}"
fi

log() { printf '==> %s\n' "$*"; }

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported --arch '$ARCH' (expected arm64 or x86_64)" >&2
    exit 2
    ;;
esac

# ---------- Resolve signing identity -----------------------------------------
# Prefer a Developer ID Application cert so macOS keys TCC/Gatekeeper grants on a
# stable identity (per-app permissions survive reinstalls). Fall back to ad-hoc.
if [[ "$FORCE_ADHOC" == "1" ]]; then
  SIGN_IDENTITY="-"
elif [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  log "code signing: ad-hoc (no Developer ID identity found)"
else
  log "code signing: $SIGN_IDENTITY"
fi

notarytool_args=()
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  notarytool_args=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  notarytool_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
fi

SHOULD_NOTARIZE=0
NOTARIZATION_STATUS="skipped"
case "$NOTARIZE" in
  never)
    NOTARIZATION_STATUS="skipped (--skip-notarize)"
    ;;
  auto)
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
      NOTARIZATION_STATUS="skipped (ad-hoc signing)"
    elif [[ "${#notarytool_args[@]}" -eq 0 ]]; then
      NOTARIZATION_STATUS="skipped (missing notary credentials)"
    else
      SHOULD_NOTARIZE=1
      NOTARIZATION_STATUS="pending"
    fi
    ;;
  required)
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
      echo "error: notarization requires a Developer ID signing identity; remove --adhoc or pass --sign." >&2
      exit 1
    fi
    if [[ "${#notarytool_args[@]}" -eq 0 ]]; then
      echo "error: notarization requires --notary-profile, NOTARYTOOL_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD." >&2
      exit 1
    fi
    SHOULD_NOTARIZE=1
    NOTARIZATION_STATUS="pending"
    ;;
esac

if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    log "notarization: enabled (keychain profile: $NOTARYTOOL_PROFILE)"
  else
    log "notarization: enabled (APPLE_ID/APPLE_TEAM_ID credentials)"
  fi
else
  log "notarization: $NOTARIZATION_STATUS"
fi

notarize_app() {
  local app_path="$1"
  local notary_dir notary_zip submit_json submit_id submit_status

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun not found. Install Xcode." >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found; required to parse notarytool output." >&2
    exit 1
  fi

  notary_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-notary.XXXXXX")"
  notary_zip="$notary_dir/cmux-notary.zip"

  log "creating notarization archive"
  ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_zip"

  log "submitting app for notarization"
  if ! submit_json="$(xcrun notarytool submit "$notary_zip" "${notarytool_args[@]}" --wait --output-format json)"; then
    rm -rf "$notary_dir"
    echo "error: notarization submission failed" >&2
    exit 1
  fi

  submit_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"$submit_json")"
  submit_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<<"$submit_json")"
  if [[ "$submit_status" != "Accepted" ]]; then
    echo "error: app notarization failed with status: ${submit_status:-unknown}" >&2
    if [[ -n "$submit_id" ]]; then
      xcrun notarytool log "$submit_id" "${notarytool_args[@]}" || true
    fi
    rm -rf "$notary_dir"
    exit 1
  fi

  log "stapling notarization ticket"
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  rm -rf "$notary_dir"
  NOTARIZATION_STATUS="notarized"
}

# ---------- Homebrew + submodule preflight -----------------------------------
if [[ "$SKIP_DEPS" == "0" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew not found on PATH. Install from https://brew.sh and re-run." >&2
    exit 1
  fi

  for formula in "${BREW_FORMULAE[@]}"; do
    if brew list --formula --versions "$formula" >/dev/null 2>&1; then
      log "brew: $formula already installed"
    else
      log "brew install $formula"
      brew install "$formula"
    fi
  done

  if [[ -f "$PROJECT_DIR/.gitmodules" ]]; then
    log "git submodule update --init --recursive"
    git -C "$PROJECT_DIR" submodule update --init --recursive
  fi
fi

# ---------- Prerequisites -----------------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found. Install Xcode." >&2
    exit 1
  fi

  # Xcode 26 ships the Metal shader compiler as a separately downloadable
  # component. Without it, Ghostty's metallib build phase fails with
  # "cannot execute tool 'metal' due to missing Metal Toolchain". Probe for
  # it and fetch it on demand (~700 MB, one time).
  if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    log "Metal Toolchain missing — downloading (xcodebuild -downloadComponent MetalToolchain)"
    xcodebuild -downloadComponent MetalToolchain
  fi

  zig_version="$(zig version 2>/dev/null || true)"
  if [[ "$zig_version" != 0.15.* ]]; then
    if [[ -x /opt/homebrew/opt/zig@0.15/bin/zig ]]; then
      export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
      zig_version="$(zig version 2>/dev/null || true)"
      log "using zig at /opt/homebrew/opt/zig@0.15/bin ($zig_version)"
    fi
  fi
  if [[ "$zig_version" != 0.15.* ]]; then
    echo "error: zig 0.15.x required (have ${zig_version:-none})." >&2
    echo "       brew install zig@0.15" >&2
    exit 1
  fi

  # Ensure GhosttyKit.xcframework exists before xcodebuild. The Xcode project
  # links it as a dependency, so it must be present when the build graph is
  # constructed — a Run Script phase can't create it in time. ensure-ghosttykit
  # downloads a checksum-pinned prebuilt or builds it from the ghostty submodule.
  log "ensuring GhosttyKit.xcframework (scripts/ensure-ghosttykit.sh)"
  "$SCRIPT_DIR/ensure-ghosttykit.sh"
fi

# ---------- Build (unless skipped) -------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  XCODE_BUILD_ARGS=(
    -project GhosttyTabs.xcodeproj
    -scheme cmux
    -configuration "$CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA"
    -destination "platform=macOS,arch=$ARCH"
    ARCHS="$ARCH"
    ONLY_ACTIVE_ARCH=YES
    CODE_SIGNING_ALLOWED=NO
  )
  if [[ "$DEBUG_BUILD" == "1" ]]; then
    # Override only the bundle id (suffixed) and CFBundle display strings.
    # PRODUCT_NAME is intentionally left alone — see SOURCE_APP comment above.
    XCODE_BUILD_ARGS+=(
      PRODUCT_BUNDLE_IDENTIFIER="$DEBUG_BUNDLE_ID"
      INFOPLIST_KEY_CFBundleName="cmux-debug"
      INFOPLIST_KEY_CFBundleDisplayName="cmux-debug"
    )
  fi
  XCODE_BUILD_ARGS+=(build)
  log "building $CONFIGURATION ($ARCH) into $DERIVED_DATA"
  xcodebuild "${XCODE_BUILD_ARGS[@]}" >/tmp/install-fork-build.log 2>&1 || {
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
# `codesign --deep` rejects bundles carrying com.apple.FinderInfo or resource
# forks ("resource fork, Finder information, or similar detritus not allowed").
# Strip xattrs first, then sign helper executables and nested code before the
# outer bundle so the app's resource manifest sees signed embedded code.
log "stripping extended attributes from $TARGET"
xattr -cr "$TARGET" 2>/dev/null || true

sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # Notarization requires a secure timestamp and hardened runtime.
  sign_args+=(--options runtime --timestamp)
fi

sign_or_warn() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    echo "error: codesign failed for $description; notarization requires all embedded code to be Developer ID signed" >&2
    exit 1
  fi

  echo "warning: codesign failed for $description" >&2
}

if [[ "$SHOULD_NOTARIZE" == "1" && ! -f "$HELPER_ENTITLEMENTS" ]]; then
  echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2
  exit 1
fi

if [[ -d "$TARGET/Contents/Resources/bin" ]]; then
  log "codesigning helper executables"
  while IFS= read -r -d '' helper; do
    [[ -f "$helper" && -x "$helper" ]] || continue

    helper_sign_args=("${sign_args[@]}")
    if [[ -f "$HELPER_ENTITLEMENTS" ]]; then
      helper_sign_args+=(--entitlements "$HELPER_ENTITLEMENTS")
    fi

    sign_or_warn "$helper" codesign "${helper_sign_args[@]}" "$helper"
  done < <(find "$TARGET/Contents/Resources/bin" -maxdepth 1 -type f -print0 2>/dev/null)
fi

log "codesigning nested bundles"
while IFS= read -r nested; do
  sign_or_warn "$nested" codesign "${sign_args[@]}" --deep "$nested"
done < <(find "$TARGET/Contents/Frameworks" "$TARGET/Contents/PlugIns" \
  -mindepth 1 -maxdepth 4 -type d \
  \( -name "*.framework" -o -name "*.appex" -o -name "*.app" -o -name "*.bundle" -o -name "*.plugin" -o -name "*.xpc" \) \
  2>/dev/null | sort -r)

log "codesigning $TARGET"
codesign "${sign_args[@]}" "$TARGET" >/dev/null 2>&1 || {
  if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    echo "error: codesign failed; notarization requires a valid Developer ID signature" >&2
    exit 1
  fi
  echo "warning: codesign failed; the app may not launch on a hardened-runtime system" >&2
}

if ! codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
  if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    echo "error: codesign --verify failed for $TARGET; notarization requires a valid signature" >&2
    exit 1
  fi
  echo "warning: codesign --verify failed for $TARGET" >&2
fi

if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
  notarize_app "$TARGET"
fi

log "removing com.apple.quarantine attribute"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# ---------- Verify -----------------------------------------------------------
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Contents/Info.plist" 2>/dev/null || echo cmux)"
binary="$TARGET/Contents/MacOS/$bundle_executable"
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
echo "  signed by:  $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$SIGN_IDENTITY")"
echo "  notarized:  $NOTARIZATION_STATUS"
echo
log "to launch:"
echo "  open \"$TARGET\""
