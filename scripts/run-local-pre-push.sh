#!/usr/bin/env bash
set -euo pipefail

if git rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
  CHANGED_FILES="$(git diff --name-only @{upstream}..HEAD)"
elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
  CHANGED_FILES="$(git diff --name-only HEAD~1..HEAD)"
else
  CHANGED_FILES="$(git ls-files)"
fi

if [[ -z "${CHANGED_FILES}" ]]; then
  exit 0
fi

source "$(git rev-parse --show-toplevel)/scripts/local-hooks-lib.sh"

run_docs_guardrails
run_ui_guardrails

if has_changed '^\.github/workflows/'; then
  run_workflow_yaml_validation
fi

if has_changed '^(Sources/|Tests/|OfficeResume\.xcodeproj/|OfficeResume\.xcworkspace/|project\.yml$)'; then
  run_xcode_suite
fi

if has_changed '^OfficeResumeBackend/'; then
  run_backend_lint
  run_backend_tests
fi

if has_changed '^site/'; then
  run_site_dry_run
fi
