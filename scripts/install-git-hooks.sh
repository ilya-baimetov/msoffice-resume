#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

chmod +x .githooks/pre-commit .githooks/pre-push
chmod +x scripts/install-git-hooks.sh scripts/local-hooks-lib.sh scripts/run-local-pre-commit.sh scripts/run-local-pre-push.sh scripts/review-local.sh scripts/check-local.sh

git config core.hooksPath .githooks

echo "Repo-managed git hooks installed."
echo "Active hooks path: $(git config --get core.hooksPath)"
