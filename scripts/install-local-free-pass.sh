#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "scripts/install-local-free-pass.sh is deprecated. Using scripts/install-local-dev.sh instead."
exec "$SCRIPT_DIR/install-local-dev.sh" "$@"
