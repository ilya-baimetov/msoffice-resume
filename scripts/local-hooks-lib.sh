#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

log_step() {
  printf '\n[local-hooks] %s\n' "$1"
}

has_changed() {
  local pattern="$1"
  if [[ -z "${CHANGED_FILES:-}" ]]; then
    return 1
  fi
  printf '%s\n' "$CHANGED_FILES" | grep -Eq "$pattern"
}

run_docs_guardrails() {
  log_step "Running docs consistency"
  bash scripts/eval-docs-consistency.sh
}

run_ui_guardrails() {
  log_step "Running UI guardrails"
  bash scripts/eval-ui-guardrails.sh
}

run_workflow_yaml_validation() {
  log_step "Validating GitHub workflow YAML"
  ruby -e 'require "yaml"; Dir[".github/workflows/*.yml"].sort.each { |path| YAML.load_file(path); puts "OK #{path}" }'
}

run_backend_lint() {
  log_step "Running backend lint"
  (
    cd OfficeResumeBackend
    npm run lint
  )
}

run_backend_tests() {
  log_step "Running backend tests"
  (
    cd OfficeResumeBackend
    npm test
  )
}

run_site_dry_run() {
  log_step "Running site Worker dry-run"
  (
    cd site
    npx wrangler deploy --dry-run
  )
}

run_xcode_suite() {
  local target_type
  local target_path

  if [[ -d "OfficeResume.xcworkspace" ]]; then
    target_type="workspace"
    target_path="OfficeResume.xcworkspace"
  elif [[ -d "OfficeResume.xcodeproj" ]]; then
    target_type="project"
    target_path="OfficeResume.xcodeproj"
  else
    echo "[local-hooks] No Xcode workspace or project found." >&2
    return 1
  fi

  log_step "Running macOS build/test suite"

  xcodebuild \
    -"${target_type}" "$target_path" \
    -scheme OfficeResumeDirect \
    -destination 'platform=macOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build test

  xcodebuild \
    -"${target_type}" "$target_path" \
    -scheme OfficeResumeMAS \
    -destination 'platform=macOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build test

  xcodebuild \
    -"${target_type}" "$target_path" \
    -scheme OfficeResumeHelper \
    -destination 'platform=macOS' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build
}
