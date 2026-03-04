#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

has_rg=false
if command -v rg >/dev/null 2>&1; then
  has_rg=true
fi

has_pattern() {
  local pattern="$1"
  shift
  if ${has_rg}; then
    rg -q --pcre2 "$pattern" "$@"
  else
    grep -Eq "$pattern" "$@"
  fi
}

require_pattern() {
  local pattern="$1"
  local target="$2"
  local label="$3"
  if has_pattern "$pattern" "$target"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_pattern() {
  local pattern="$1"
  local target="$2"
  local label="$3"
  if has_pattern "$pattern" "$target"; then
    fail "$label"
  else
    pass "$label"
  fi
}

echo "== UI Guardrails =="

require_pattern 'MenuBarExtra\(' "Sources/MenuUIShared/OfficeResumeMenuUI.swift" \
  "Menu UI uses MenuBarExtra"

forbid_pattern '\.menuBarExtraStyle\s*\(\s*\.window\s*\)' "Sources/MenuUIShared" \
  "No window-style MenuBarExtra"

forbid_pattern 'WindowGroup\s*\{' "Sources/MenuUIShared" \
  "No WindowGroup scene in shared menu UI"
forbid_pattern 'WindowGroup\s*\{' "Sources/OfficeResumeDirect" \
  "No WindowGroup scene in Direct target"
forbid_pattern 'WindowGroup\s*\{' "Sources/OfficeResumeMAS" \
  "No WindowGroup scene in MAS target"

forbid_pattern 'NSPopover|NSPanel|NSWindow' "Sources/MenuUIShared" \
  "No custom AppKit popover/window shell in shared menu UI"

forbid_pattern 'OneNote' "Sources/MenuUIShared" \
  "No dedicated OneNote messaging in menu UI"

echo
echo "== Summary =="
echo "Failures: $failures"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "UI guardrails passed."
