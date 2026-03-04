#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$REPO_ROOT/OfficeResume.xcworkspace"
PROJECT_FILE="$REPO_ROOT/OfficeResume.xcodeproj/project.pbxproj"
PROJECT_YML="$REPO_ROOT/project.yml"
BUILD_DIR="$REPO_ROOT/dist/release-build"
OUT_DIR="$REPO_ROOT/dist/release-direct"
UNSIGNED_ZIP="$REPO_ROOT/dist/OfficeResume-direct-unsigned.zip"
SIGNED_ZIP="$REPO_ROOT/dist/OfficeResume-direct-signed.zip"
CONFIGURATION="${CONFIGURATION:-Release}"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"

DIRECT_APP="$OUT_DIR/OfficeResumeDirect.app"
HELPER_APP="$OUT_DIR/OfficeResumeHelper.app"
DIRECT_ENTITLEMENTS="$REPO_ROOT/Sources/OfficeResumeDirect/OfficeResumeDirect.entitlements"
HELPER_ENTITLEMENTS="$REPO_ROOT/Sources/OfficeResumeHelper/OfficeResumeHelper.entitlements"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)." >&2
  exit 1
fi

if [[ ! -d "$WORKSPACE" || "$PROJECT_YML" -nt "$PROJECT_FILE" ]]; then
  echo "Generating Xcode project..."
  (cd "$REPO_ROOT" && xcodegen generate)
fi

mkdir -p "$BUILD_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

build_target() {
  local scheme="$1"
  local log_file="$REPO_ROOT/dist/${scheme}-release.log"

  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -configuration "$CONFIGURATION" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >"$log_file"

  echo "Built $scheme ($CONFIGURATION). Log: $log_file"
}

echo "Building release artifacts..."
build_target "OfficeResumeDirect"
build_target "OfficeResumeHelper"

cp -R "$BUILD_DIR/OfficeResumeDirect.app" "$DIRECT_APP"
cp -R "$BUILD_DIR/OfficeResumeHelper.app" "$HELPER_APP"

(
  cd "$REPO_ROOT/dist"
  rm -f "$(basename "$UNSIGNED_ZIP")"
  zip -qry "$(basename "$UNSIGNED_ZIP")" "$(basename "$OUT_DIR")"
)

echo "Unsigned zip: $UNSIGNED_ZIP"

if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Signing helper and direct apps with Developer ID certificate..."

  find "$HELPER_APP/Contents/Frameworks" -type f -perm -111 -print0 2>/dev/null | while IFS= read -r -d '' binary; do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$binary"
  done

  find "$DIRECT_APP/Contents/Frameworks" -type f -perm -111 -print0 2>/dev/null | while IFS= read -r -d '' binary; do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$binary"
  done

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$HELPER_ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$HELPER_APP"

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$DIRECT_ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$DIRECT_APP"

  codesign --verify --deep --strict --verbose=2 "$HELPER_APP"
  codesign --verify --deep --strict --verbose=2 "$DIRECT_APP"

  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    echo "Submitting signed zip for notarization..."
    (
      cd "$REPO_ROOT/dist"
      rm -f "$(basename "$SIGNED_ZIP")"
      zip -qry "$(basename "$SIGNED_ZIP")" "$(basename "$OUT_DIR")"
    )

    xcrun notarytool submit "$SIGNED_ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait

    echo "Stapling notarization tickets..."
    xcrun stapler staple "$HELPER_APP"
    xcrun stapler staple "$DIRECT_APP"

    (
      cd "$REPO_ROOT/dist"
      rm -f "$(basename "$SIGNED_ZIP")"
      zip -qry "$(basename "$SIGNED_ZIP")" "$(basename "$OUT_DIR")"
    )

    echo "Signed + notarized zip: $SIGNED_ZIP"
  else
    echo "NOTARYTOOL_PROFILE not set; skipping notarization."
  fi
else
  echo "DEVELOPER_ID_APPLICATION not set; skipping signing/notarization."
fi

cat <<MSG

Release output ready.

Folder:
  $OUT_DIR

Unsigned zip:
  $UNSIGNED_ZIP

Optional signing env vars:
  DEVELOPER_ID_APPLICATION='Developer ID Application: <Name> (<TEAMID>)'
  NOTARYTOOL_PROFILE='<stored-notarytool-profile>'
MSG
