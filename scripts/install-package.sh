#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PKG_PATH="${1:-$REPO_ROOT/dist/OfficeResume.pkg}"

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Missing package: $PKG_PATH" >&2
  exit 1
fi

installer -pkg "$PKG_PATH" -target /

cat <<MSG

Installed Office Resume from:
  $PKG_PATH

Expected install paths:
  /Applications/Office Resume.app
  /Applications/Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app
MSG
