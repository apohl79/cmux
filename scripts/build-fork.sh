#!/usr/bin/env bash
# Build a Release cmux.app from the current worktree, sign/notarize it, package
# it as a zip, and publish it to the apohl79/cmux fork release.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-fork.sh [options]

Builds Release cmux.app, signs/notarizes a staged copy, zips it, creates the
fork GitHub release if needed, and uploads the zip with --clobber.

Options:
  --skip-build              Use the pre-built artifact instead of running xcodebuild.
  --skip-deps               Skip Homebrew/submodule preflight.
  --source <path>           App bundle to package when --skip-build is used.
  --arch <arm64|x86_64>     Override host arch detection (default: uname -m).
  --sign <identity>         Codesign with a specific identity.
  --adhoc                   Force ad-hoc signing even if Developer ID exists.
  --notarize                Require notarization after Developer ID signing.
  --skip-notarize           Disable auto notarization.
  --notary-profile <name>   Use a notarytool keychain profile.
  --repo <owner/repo>       GitHub repo for the fork release (default: apohl79/cmux).
  --version <version>       Release version (default: <MARKETING_VERSION>-apohl79).
  --tag <tag>               GitHub release tag (default: release version).
  --asset-name <name>       Release asset name (default: cmux-<version>-macos.zip).
  --output-dir <path>       Directory for the zip (default: build/fork-artifacts).
  --no-upload               Build/sign/notarize/zip only; do not create/upload release.
  -h, --help                Show this help.

Environment:
  NOTARIZE=1 APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=...
  NOTARYTOOL_PROFILE=cmux-notary ./scripts/build-fork.sh
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-cmux}"
FORK_REPO="${FORK_REPO:-apohl79/cmux}"
SKIP_BUILD=0
SKIP_DEPS=0
ARCH="${ARCH:-$(uname -m)}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/fork}"
SOURCE_APP="${SOURCE_APP:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build/fork-artifacts}"
VERSION_OVERRIDE="${VERSION:-}"
TAG_OVERRIDE="${TAG:-}"
ASSET_NAME_OVERRIDE="${ASSET_NAME:-}"
UPLOAD=1
BUILD_LOG="${BUILD_LOG:-/tmp/build-fork-build.log}"

# Code signing identity. Empty = auto-detect a Developer ID Application cert
# from the keychain (falls back to ad-hoc "-"). Override with --sign, or force
# ad-hoc via --adhoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
FORCE_ADHOC=0
NOTARIZE="${NOTARIZE:-auto}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"

BREW_FORMULAE=(zig@0.15)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --source) SOURCE_APP="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --notarize) NOTARIZE=required; shift ;;
    --skip-notarize) NOTARIZE=never; shift ;;
    --notary-profile) NOTARYTOOL_PROFILE="$2"; shift 2 ;;
    --repo) FORK_REPO="$2"; shift 2 ;;
    --version) VERSION_OVERRIDE="$2"; shift 2 ;;
    --tag) TAG_OVERRIDE="$2"; shift 2 ;;
    --asset-name) ASSET_NAME_OVERRIDE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --debug)
      echo "error: build-fork publishes Release builds only; Debug installs are not release assets." >&2
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

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported --arch '$ARCH' (expected arm64 or x86_64)" >&2
    exit 2
    ;;
esac

case "$NOTARIZE" in
  auto|required|never) ;;
  1|true|TRUE|yes|YES|always) NOTARIZE=required ;;
  0|false|FALSE|no|NO|off) NOTARIZE=never ;;
  *)
    echo "error: unsupported NOTARIZE value '$NOTARIZE' (expected auto, 1, or 0)" >&2
    exit 2
    ;;
esac

PROJECT_FILE="$PROJECT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"
OFFICIAL_VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')"
if [[ -z "$OFFICIAL_VERSION" ]]; then
  echo "error: could not determine MARKETING_VERSION from $PROJECT_FILE" >&2
  exit 1
fi

VERSION="${VERSION_OVERRIDE:-${OFFICIAL_VERSION}-apohl79}"
TAG="${TAG_OVERRIDE:-$VERSION}"
ASSET_NAME="${ASSET_NAME_OVERRIDE:-cmux-${VERSION}-macos.zip}"
SOURCE_APP="${SOURCE_APP:-$DERIVED_DATA/Build/Products/Release/cmux.app}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ZIP_PATH="$OUTPUT_DIR/$ASSET_NAME"

if [[ "$UPLOAD" == "1" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "error: gh not found; required to create/upload the fork release." >&2
  exit 1
fi

# ---------- Resolve signing identity -----------------------------------------
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

sign_app() {
  local app_path="$1"
  local sign_args helper_sign_args

  log "stripping extended attributes from $app_path"
  xattr -cr "$app_path" 2>/dev/null || true

  sign_args=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
  fi

  if [[ "$SHOULD_NOTARIZE" == "1" && ! -f "$HELPER_ENTITLEMENTS" ]]; then
    echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2
    exit 1
  fi

  if [[ -d "$app_path/Contents/Resources/bin" ]]; then
    log "codesigning helper executables"
    while IFS= read -r -d '' helper; do
      [[ -f "$helper" && -x "$helper" ]] || continue

      helper_sign_args=("${sign_args[@]}")
      if [[ -f "$HELPER_ENTITLEMENTS" ]]; then
        helper_sign_args+=(--entitlements "$HELPER_ENTITLEMENTS")
      fi

      sign_or_warn "$helper" codesign "${helper_sign_args[@]}" "$helper"
    done < <(find "$app_path/Contents/Resources/bin" -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  log "codesigning nested bundles"
  while IFS= read -r nested; do
    sign_or_warn "$nested" codesign "${sign_args[@]}" --deep "$nested"
  done < <(find "$app_path/Contents/Frameworks" "$app_path/Contents/PlugIns" \
    -mindepth 1 -maxdepth 4 -type d \
    \( -name "*.framework" -o -name "*.appex" -o -name "*.app" -o -name "*.bundle" -o -name "*.plugin" -o -name "*.xpc" \) \
    2>/dev/null | sort -r)

  log "codesigning $app_path"
  codesign "${sign_args[@]}" "$app_path" >/dev/null 2>&1 || {
    if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
      echo "error: codesign failed; notarization requires a valid Developer ID signature" >&2
      exit 1
    fi
    echo "warning: codesign failed; the app may not launch on a hardened-runtime system" >&2
  }

  if ! codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
      echo "error: codesign --verify failed for $app_path; notarization requires a valid signature" >&2
      exit 1
    fi
    echo "warning: codesign --verify failed for $app_path" >&2
  fi

  if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    notarize_app "$app_path"
  fi
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

  if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    log "Metal Toolchain missing - downloading (xcodebuild -downloadComponent MetalToolchain)"
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

  log "ensuring GhosttyKit.xcframework (scripts/ensure-ghosttykit.sh)"
  "$SCRIPT_DIR/ensure-ghosttykit.sh"
fi

# ---------- Build (unless skipped) -------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  XCODE_BUILD_ARGS=(
    -project GhosttyTabs.xcodeproj
    -scheme cmux
    -configuration Release
    -derivedDataPath "$DERIVED_DATA"
    -destination "platform=macOS,arch=$ARCH"
    ARCHS="$ARCH"
    ONLY_ACTIVE_ARCH=YES
    CODE_SIGNING_ALLOWED=NO
    build
  )

  log "building Release ($ARCH) into $DERIVED_DATA"
  xcodebuild "${XCODE_BUILD_ARGS[@]}" >"$BUILD_LOG" 2>&1 || {
      echo "error: build failed. tail of $BUILD_LOG:" >&2
      tail -30 "$BUILD_LOG" >&2
      exit 1
    }
  log "build succeeded"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: source app not found at $SOURCE_APP" >&2
  echo "       run without --skip-build, or pass --source <path>" >&2
  exit 1
fi

# ---------- Stage, sign/notarize, and package --------------------------------
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-fork-build.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

STAGED_APP="$STAGING_ROOT/${APP_NAME}.app"
log "staging app at $STAGED_APP"
ditto "$SOURCE_APP" "$STAGED_APP"

sign_app "$STAGED_APP"

rm -f "$ZIP_PATH"
log "creating release zip: $ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP_PATH"

ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

# ---------- GitHub release ----------------------------------------------------
if [[ "$UPLOAD" == "1" ]]; then
  if gh release view "$TAG" --repo "$FORK_REPO" >/dev/null 2>&1; then
    log "release exists: $FORK_REPO@$TAG"
  else
    log "creating release: $FORK_REPO@$TAG"
    gh release create "$TAG" \
      --repo "$FORK_REPO" \
      --title "$VERSION" \
      --notes "Fork build for cmux ${OFFICIAL_VERSION}."
  fi

  log "uploading $ASSET_NAME with --clobber"
  gh release upload "$TAG" "$ZIP_PATH" --repo "$FORK_REPO" --clobber
fi

log "fork build ready"
echo "  repo:       $FORK_REPO"
echo "  version:    $VERSION"
echo "  tag:        $TAG"
echo "  asset:      $ASSET_NAME"
echo "  zip:        $ZIP_PATH"
echo "  sha256:     $ZIP_SHA256"
echo "  signed by:  $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$SIGN_IDENTITY")"
echo "  notarized:  $NOTARIZATION_STATUS"
