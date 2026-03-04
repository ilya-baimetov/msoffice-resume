#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

LOCAL_VERSION="${DIRECT_PKG_VERSION:-0.0.0-dev.$(date +%Y%m%d%H%M)}"
LOCAL_PKG="$REPO_ROOT/dist/OfficeResume-local-dev.pkg"

CONFIGURATION=Debug \
DIRECT_PKG_VERSION="$LOCAL_VERSION" \
"$SCRIPT_DIR/release-direct.sh"

cp "$REPO_ROOT/dist/OfficeResume-direct-unsigned.pkg" "$LOCAL_PKG"

cat <<MSG

Local dev package ready.

Package:
  $LOCAL_PKG

Install:
  sudo "$SCRIPT_DIR/install-local-dev.sh" "$LOCAL_PKG"
MSG
