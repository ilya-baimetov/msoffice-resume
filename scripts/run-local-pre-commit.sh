#!/usr/bin/env bash
set -euo pipefail

CHANGED_FILES="$(git diff --cached --name-only --diff-filter=ACMR)"
if [[ -z "${CHANGED_FILES}" ]]; then
  exit 0
fi

source "$(git rev-parse --show-toplevel)/scripts/local-hooks-lib.sh"

run_docs_guardrails
run_ui_guardrails

if has_changed '^\.github/workflows/'; then
  run_workflow_yaml_validation
fi

if has_changed '^OfficeResumeBackend/'; then
  run_backend_lint
fi
