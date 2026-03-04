#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "scripts/package-local-free-pass.sh is deprecated. Using scripts/package-local-dev.sh instead."
exec "$SCRIPT_DIR/package-local-dev.sh" "$@"
