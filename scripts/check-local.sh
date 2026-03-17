#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/check-local.sh [fast|full]

Modes:
  fast  Simulate local pre-commit checks against current local changes
  full  Simulate local pre-push checks against current local changes and upstream delta
EOF
}

mode="${1:-full}"

collect_local_changes() {
  {
    git diff --cached --name-only --diff-filter=ACMR
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
}

collect_full_changes() {
  {
    if git rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
      git diff --name-only @{upstream}..HEAD
    elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      git diff --name-only HEAD~1..HEAD
    else
      git ls-files
    fi
    collect_local_changes
  } | sed '/^$/d' | sort -u
}

source "$(git rev-parse --show-toplevel)/scripts/local-hooks-lib.sh"

case "$mode" in
  fast)
    CHANGED_FILES="$(collect_local_changes)"
    if [[ -z "${CHANGED_FILES}" ]]; then
      echo "[local-check] No local changes detected."
      exit 0
    fi

    run_docs_guardrails
    run_ui_guardrails

    if has_changed '^\.github/workflows/'; then
      run_workflow_yaml_validation
    fi

    if has_changed '^OfficeResumeBackend/'; then
      run_backend_lint
    fi
    ;;
  full)
    CHANGED_FILES="$(collect_full_changes)"
    if [[ -z "${CHANGED_FILES}" ]]; then
      echo "[local-check] No local or upstream changes detected."
      exit 0
    fi

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
    ;;
  *)
    usage
    exit 1
    ;;
esac
