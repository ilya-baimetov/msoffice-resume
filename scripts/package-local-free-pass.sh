#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$REPO_ROOT/OfficeResume.xcworkspace"
PROJECT_FILE="$REPO_ROOT/OfficeResume.xcodeproj/project.pbxproj"
PROJECT_YML="$REPO_ROOT/project.yml"
BUILD_DIR="$REPO_ROOT/dist/build"
PACKAGE_DIR="$REPO_ROOT/dist/local-free-pass"
ZIP_PATH="$REPO_ROOT/dist/OfficeResume-local-free-pass.zip"
CONFIGURATION="${CONFIGURATION:-Debug}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and command line tools first." >&2
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
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

build_target() {
  local scheme="$1"
  local log_file="$REPO_ROOT/dist/${scheme}-build.log"

  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -configuration "$CONFIGURATION" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >"$log_file"

  echo "Built $scheme (log: $log_file)"
}

echo "Building OfficeResumeDirect ($CONFIGURATION)..."
build_target "OfficeResumeDirect"

echo "Building OfficeResumeHelper ($CONFIGURATION)..."
build_target "OfficeResumeHelper"

for app in OfficeResumeDirect.app OfficeResumeHelper.app; do
  if [[ ! -d "$BUILD_DIR/$app" ]]; then
    echo "Expected build output missing: $BUILD_DIR/$app" >&2
    exit 1
  fi

  cp -R "$BUILD_DIR/$app" "$PACKAGE_DIR/$app"
done

cp "$SCRIPT_DIR/install-local-free-pass.sh" "$PACKAGE_DIR/install-local-free-pass.sh"
chmod +x "$PACKAGE_DIR/install-local-free-pass.sh"

cat > "$PACKAGE_DIR/README.txt" <<'TXT'
Office Resume - local free-pass bundle

1) Run:
   ./install-local-free-pass.sh

Optional install location:
   ./install-local-free-pass.sh . /Applications

Notes:
- Default install location is ~/Applications/OfficeResumeLocal
- Installer enables free-pass mode by writing:
  ~/Library/Application Support/com.pragprod.msofficeresume/entitlements/free-pass-v1.json
TXT

mkdir -p "$REPO_ROOT/dist"
(
  cd "$REPO_ROOT/dist"
  rm -f "$(basename "$ZIP_PATH")"
  zip -qry "$(basename "$ZIP_PATH")" "$(basename "$PACKAGE_DIR")"
)

cat <<MSG
Local free-pass package ready.

Folder:
  $PACKAGE_DIR

Zip:
  $ZIP_PATH

Install now:
  "$PACKAGE_DIR/install-local-free-pass.sh"
MSG
