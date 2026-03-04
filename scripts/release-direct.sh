#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$REPO_ROOT/OfficeResume.xcworkspace"
PROJECT_FILE="$REPO_ROOT/OfficeResume.xcodeproj/project.pbxproj"
PROJECT_YML="$REPO_ROOT/project.yml"
BUILD_DIR="$REPO_ROOT/dist/release-build"
OUT_DIR="$REPO_ROOT/dist/release-direct"
PAYLOAD_DIR="$OUT_DIR/payload"
COMPONENT_PLIST="$OUT_DIR/components.plist"
PKG_SCRIPTS_DIR="$REPO_ROOT/scripts/pkg/direct"
UNSIGNED_PKG="$REPO_ROOT/dist/OfficeResume-direct-unsigned.pkg"
SIGNED_PKG="$REPO_ROOT/dist/OfficeResume-direct-signed.pkg"
CONFIGURATION="${CONFIGURATION:-Release}"
PKG_IDENTIFIER="${DIRECT_PKG_IDENTIFIER:-com.pragprod.msofficeresume.direct}"
PKG_VERSION="${DIRECT_PKG_VERSION:-$(date +%Y.%m.%d.%H%M)}"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"

DIRECT_APP="$OUT_DIR/OfficeResume.app"
HELPER_APP="$OUT_DIR/OfficeResumeHelper.app"
INSTALL_APP_NAME="Office Resume.app"
INSTALL_APP_PATH="$PAYLOAD_DIR/Applications/$INSTALL_APP_NAME"
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

if ! command -v pkgbuild >/dev/null 2>&1; then
  echo "pkgbuild is required (Xcode command line tools)." >&2
  exit 1
fi

if [[ ! -d "$WORKSPACE" || "$PROJECT_YML" -nt "$PROJECT_FILE" ]]; then
  echo "Generating Xcode project..."
  (cd "$REPO_ROOT" && xcodegen generate)
fi

mkdir -p "$BUILD_DIR"
rm -rf "$OUT_DIR" "$UNSIGNED_PKG" "$SIGNED_PKG"
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

sign_app_bundle() {
  local app_path="$1"
  local entitlements="$2"

  find "$app_path/Contents/Frameworks" -type f -perm -111 -print0 2>/dev/null | while IFS= read -r -d '' binary; do
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APPLICATION" "$binary"
  done

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$entitlements" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$app_path"

  codesign --verify --deep --strict --verbose=2 "$app_path"
}

echo "Building release artifacts..."
build_target "OfficeResumeDirect"
build_target "OfficeResumeHelper"

cp -R "$BUILD_DIR/OfficeResume.app" "$DIRECT_APP"
cp -R "$BUILD_DIR/OfficeResumeHelper.app" "$HELPER_APP"

mkdir -p "$DIRECT_APP/Contents/Library/LoginItems"
rm -rf "$DIRECT_APP/Contents/Library/LoginItems/OfficeResumeHelper.app"
cp -R "$HELPER_APP" "$DIRECT_APP/Contents/Library/LoginItems/OfficeResumeHelper.app"

if [[ -n "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Signing app bundles with Developer ID Application certificate..."
  sign_app_bundle "$DIRECT_APP/Contents/Library/LoginItems/OfficeResumeHelper.app" "$HELPER_ENTITLEMENTS"
  sign_app_bundle "$DIRECT_APP" "$DIRECT_ENTITLEMENTS"
else
  echo "DEVELOPER_ID_APPLICATION not set; app bundles remain unsigned."
fi

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR/Applications"
cp -R "$DIRECT_APP" "$INSTALL_APP_PATH"

# Force app bundles to remain installed at /Applications and avoid PackageKit relocation.
pkgbuild --analyze --root "$PAYLOAD_DIR" "$COMPONENT_PLIST"
component_index=0
while /usr/libexec/PlistBuddy -c "Print :$component_index" "$COMPONENT_PLIST" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :$component_index:BundleIsRelocatable false" "$COMPONENT_PLIST"
  component_index=$((component_index + 1))
done

if [[ ! -d "$PKG_SCRIPTS_DIR" ]]; then
  echo "Missing package scripts directory: $PKG_SCRIPTS_DIR" >&2
  exit 1
fi

pkgbuild \
  --root "$PAYLOAD_DIR" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$PKG_VERSION" \
  --install-location "/" \
  --scripts "$PKG_SCRIPTS_DIR" \
  "$UNSIGNED_PKG"

echo "Unsigned pkg: $UNSIGNED_PKG"

FINAL_PKG="$UNSIGNED_PKG"
if [[ -n "$DEVELOPER_ID_INSTALLER" ]]; then
  echo "Signing pkg with Developer ID Installer certificate..."
  productsign --sign "$DEVELOPER_ID_INSTALLER" "$UNSIGNED_PKG" "$SIGNED_PKG"
  pkgutil --check-signature "$SIGNED_PKG"
  FINAL_PKG="$SIGNED_PKG"

  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    echo "Submitting pkg for notarization..."
    xcrun notarytool submit "$SIGNED_PKG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$SIGNED_PKG"
    xcrun stapler validate "$SIGNED_PKG"
    echo "Signed + notarized pkg: $SIGNED_PKG"
  else
    echo "NOTARYTOOL_PROFILE not set; skipping notarization."
  fi
else
  echo "DEVELOPER_ID_INSTALLER not set; pkg remains unsigned."
fi

cat <<MSG

Release output ready.

App payload folder:
  $OUT_DIR

Canonical installer package:
  $FINAL_PKG

Pkg metadata:
  identifier=$PKG_IDENTIFIER
  version=$PKG_VERSION

Optional signing env vars:
  DEVELOPER_ID_APPLICATION='Developer ID Application: <Name> (<TEAMID>)'
  DEVELOPER_ID_INSTALLER='Developer ID Installer: <Name> (<TEAMID>)'
  NOTARYTOOL_PROFILE='<stored-notarytool-profile>'
MSG
