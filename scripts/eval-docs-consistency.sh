#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

failures=0
warnings=0

pass() { echo "PASS: $*"; }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

has_rg=false
if command -v rg >/dev/null 2>&1; then
  has_rg=true
fi

search_in_file() {
  local pattern="$1"
  local file="$2"
  if ${has_rg}; then
    rg -q --pcre2 "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

search_in_files() {
  local pattern="$1"
  shift
  local file
  for file in "$@"; do
    if [[ -f "$file" ]] && search_in_file "$pattern" "$file"; then
      return 0
    fi
  done
  return 1
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    pass "$label exists ($path)"
  else
    fail "$label missing ($path)"
  fi
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if search_in_file "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_pattern_in_file() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if search_in_file "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_pattern_in_set() {
  local pattern="$1"
  local label="$2"
  shift 2
  if search_in_files "$pattern" "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_pattern_in_set() {
  local pattern="$1"
  local label="$2"
  shift 2
  if search_in_files "$pattern" "$@"; then
    fail "$label"
  else
    pass "$label"
  fi
}

CANONICAL_DOCS=(
  "AGENTS.md"
  "intent.md"
  "PRD.md"
  "spec.md"
  "specs/contracts.md"
  "specs/core.md"
  "specs/helper-daemon.md"
  "specs/menu-ui.md"
  "specs/backend-worker.md"
  "prompt.md"
)

SUPPORTING_DOCS=(
  "README.md"
  "services-setup.md"
  ".github/copilot-instructions.md"
  "docs/direct-only-ax-decision-memo.md"
  "docs/direct-only-ax-migration-plan.md"
  "docs/vibe-coding-methodology.md"
  "docs/eval-scorecard-template.md"
)

CHECK_DOCS=("${CANONICAL_DOCS[@]}" "${SUPPORTING_DOCS[@]}")

echo "== Docs Consistency Checks =="

for file in "${CANONICAL_DOCS[@]}"; do
  require_file "$file" "Canonical doc"
done

for file in "${SUPPORTING_DOCS[@]}"; do
  require_file "$file" "Supporting doc"
done

require_file ".github/pull_request_template.md" "Pull request template"

echo
echo "== Canonical Order Checks =="

require_pattern "AGENTS.md" "## Canonical Documents \(Precedence\)" "AGENTS contains precedence section"
require_pattern "AGENTS.md" "1\. .*AGENTS\.md" "AGENTS precedence lists AGENTS.md first"
require_pattern "AGENTS.md" "2\. .*intent\.md" "AGENTS precedence lists intent.md"
require_pattern "AGENTS.md" "3\. .*PRD\.md" "AGENTS precedence lists PRD.md"
require_pattern "AGENTS.md" "4\. .*spec\.md" "AGENTS precedence lists spec.md"
require_pattern "AGENTS.md" "7\. .*prompt\.md" "AGENTS precedence lists prompt.md"

require_pattern "prompt.md" "## Mandatory First Step" "prompt contains mandatory first step"
require_pattern "prompt.md" "1\. .*AGENTS\.md" "prompt requires AGENTS.md"
require_pattern "prompt.md" "2\. .*intent\.md" "prompt requires intent.md"
require_pattern "prompt.md" "3\. .*PRD\.md" "prompt requires PRD.md"
require_pattern "prompt.md" "4\. .*spec\.md" "prompt requires spec.md"
require_pattern "prompt.md" "5\. .*specs/contracts\.md" "prompt requires specs/contracts.md"

echo
echo "== Section Coverage Checks =="

require_pattern "intent.md" "^## Why This Exists" "intent has product motivation"
require_pattern "intent.md" "^## Product Thesis" "intent has product thesis"
require_pattern "intent.md" "CAP-001" "intent includes capability framing"

require_pattern "PRD.md" "^## 1\. Problem Statement" "PRD has problem statement"
require_pattern "PRD.md" "^## 5\. Scope and Support Matrix" "PRD has support matrix"
require_pattern "PRD.md" "^## 7\. Functional Requirements" "PRD has functional requirements"
require_pattern "PRD.md" "^## 12\. Launch Criteria \(v1\)" "PRD has launch criteria"

require_pattern "spec.md" "^## 7\. Event Capture Model" "spec has event capture model"
require_pattern "spec.md" "^## 8\. Office Adapter Behavior" "spec has office adapter behavior"
require_pattern "spec.md" "^## 16\. XPC Contract Details" "spec has XPC contract details"
require_pattern "spec.md" "^## 17\. Test Matrix" "spec has test matrix"

require_pattern "PRD.md" "verified sign-in" "PRD requires verified sign-in for Direct billing"
require_pattern "spec.md" "Checkout Session|Checkout Sessions" "spec references Direct Checkout Sessions"
require_pattern "services-setup.md" "Worker-hosted pricing page|Worker-hosted pricing" "services setup documents Worker-hosted pricing"
require_pattern "AGENTS.md" "AXObserver|Accessibility notifications" "AGENTS documents AX-first capture"
require_pattern "PRD.md" "Accessibility: click to fix" "PRD documents Accessibility UI"
require_pattern "spec.md" "NSWorkspace" "spec documents NSWorkspace as secondary lifecycle input"
require_pattern "docs/direct-only-ax-decision-memo.md" "## Decision" "decision memo has explicit decision section"
require_pattern "docs/direct-only-ax-migration-plan.md" "## Phase 0 - Contract Reset" "migration plan has phased rollout"

echo
echo "== Component Mapping Checks =="

require_pattern "AGENTS.md" "specs/core\.md" "AGENTS references core component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeCore/" "AGENTS maps core spec to source"
require_pattern "AGENTS.md" "specs/helper-daemon\.md" "AGENTS references helper component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeHelper/" "AGENTS maps helper spec to source"
require_pattern "AGENTS.md" "specs/menu-ui\.md" "AGENTS references menu component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeDirect/" "AGENTS maps menu spec to source"
require_pattern "AGENTS.md" "specs/backend-worker\.md" "AGENTS references backend component spec"
require_pattern "AGENTS.md" "OfficeResumeBackend/" "AGENTS maps backend spec to source"
require_pattern "AGENTS.md" "Copilot Review Expectations" "AGENTS defines Copilot review expectations"
require_pattern ".github/pull_request_template.md" "Copilot review URL:" "PR template includes Copilot review URL field"

echo
echo "== Bundle Prefix Drift Checks =="

require_pattern "AGENTS.md" "com\.pragprod\.msofficeresume" "AGENTS uses current bundle prefix"
forbid_pattern_in_set "com\.alemira\.msofficeresume|com\.ilya\.msofficeresume" "No stale bundle prefixes in checked docs" "${CHECK_DOCS[@]}"

if ! search_in_files "com\.pragprod\.msofficeresume" "${CHECK_DOCS[@]}"; then
  warn "No bundle prefix mentions found in checked docs"
else
  pass "Current bundle prefix appears in checked docs"
fi

echo
echo "== Direct Billing Drift Checks =="

forbid_pattern_in_set "STRIPE_SUBSCRIBE_URL" "No stale STRIPE_SUBSCRIBE_URL references in checked docs" "${CHECK_DOCS[@]}"
forbid_pattern_in_set "Payment Link|Payment Links|shareable payment link" "No Payment Link terminology in checked docs" "${CHECK_DOCS[@]}"
require_pattern "specs/backend-worker.md" "GET /billing/entry" "Backend spec documents billing entry endpoint"
require_pattern "specs/backend-worker.md" "GET /billing/pricing" "Backend spec documents pricing page endpoint"
require_pattern "specs/backend-worker.md" "POST /billing/checkout" "Backend spec documents checkout endpoint"
require_pattern "specs/menu-ui.md" "Choose Plan" "Menu UI spec documents Choose Plan action"

echo
echo "== Architecture Drift Checks =="

require_pattern_in_set "Accessibility: click to fix|Accessibility: OK" "Checked docs include Accessibility operational UI" \
  "AGENTS.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/helper-daemon.md" "specs/menu-ui.md" "prompt.md"
require_pattern_in_set "AXObserver|AX notifications|Accessibility notifications" "Checked docs include AX-first capture contract" \
  "AGENTS.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/helper-daemon.md" "prompt.md"
require_pattern_in_set "NSWorkspace" "Checked docs keep NSWorkspace as secondary lifecycle input" \
  "AGENTS.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/helper-daemon.md" "prompt.md"

forbid_pattern_in_set "StoreKit 2|App Store Connect" "Checked docs do not frame MAS as active v1 billing or shipping path" \
  "intent.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/core.md" "specs/helper-daemon.md" "specs/menu-ui.md" "prompt.md" "README.md" "services-setup.md"
forbid_pattern_in_set "app-group-first" "Checked docs do not rely on app-group-first storage as the active design" \
  "intent.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/core.md" "specs/helper-daemon.md" "specs/menu-ui.md" "prompt.md" "README.md" "services-setup.md"
forbid_pattern_in_set "without Accessibility dependency|no Accessibility dependency|Do not depend on Accessibility APIs" "Checked docs do not preserve the deprecated no-AX contract" \
  "intent.md" "PRD.md" "spec.md" "specs/contracts.md" "specs/core.md" "specs/helper-daemon.md" "specs/menu-ui.md" "prompt.md" "README.md" "services-setup.md"

echo
echo "== Summary =="
echo "Failures: $failures"
echo "Warnings: $warnings"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "Docs consistency checks passed."
