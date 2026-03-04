#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:-$SCRIPT_DIR}"
INSTALL_ROOT="${2:-$HOME/Applications/OfficeResumeLocal}"
APP_SUPPORT_ROOT="$HOME/Library/Application Support/com.pragprod.msofficeresume/entitlements"
FREE_PASS_FILE="$APP_SUPPORT_ROOT/free-pass-v1.json"

DIRECT_APP="$SOURCE_DIR/OfficeResumeDirect.app"
HELPER_APP="$SOURCE_DIR/OfficeResumeHelper.app"

if [[ ! -d "$DIRECT_APP" ]]; then
  echo "Missing app bundle: $DIRECT_APP" >&2
  exit 1
fi

if [[ ! -d "$HELPER_APP" ]]; then
  echo "Missing app bundle: $HELPER_APP" >&2
  exit 1
fi

mkdir -p "$INSTALL_ROOT"

rm -rf "$INSTALL_ROOT/OfficeResumeDirect.app"
rm -rf "$INSTALL_ROOT/OfficeResumeHelper.app"
cp -R "$DIRECT_APP" "$INSTALL_ROOT/OfficeResumeDirect.app"
cp -R "$HELPER_APP" "$INSTALL_ROOT/OfficeResumeHelper.app"

xattr -dr com.apple.quarantine "$INSTALL_ROOT/OfficeResumeDirect.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "$INSTALL_ROOT/OfficeResumeHelper.app" 2>/dev/null || true

mkdir -p "$APP_SUPPORT_ROOT"
cat > "$FREE_PASS_FILE" <<'JSON'
{
  "localModeEnabled": true,
  "freePassDeviceIDs": [],
  "freePassEmails": []
}
JSON

killall OfficeResumeDirect 2>/dev/null || true
killall OfficeResumeHelper 2>/dev/null || true

open "$INSTALL_ROOT/OfficeResumeDirect.app"

cat <<MSG
Office Resume installed in free-pass mode.

Install root:
  $INSTALL_ROOT

Free-pass config:
  $FREE_PASS_FILE

To disable free-pass later:
  rm "$FREE_PASS_FILE"
MSG
