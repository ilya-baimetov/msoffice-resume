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

search_in_repo_with_glob() {
  local pattern="$1"
  local file_glob="$2"
  if ${has_rg}; then
    rg -q --pcre2 "$pattern" --glob "$file_glob" .
  else
    local matched=false
    while IFS= read -r -d '' file; do
      matched=true
      if grep -Eq "$pattern" "$file"; then
        return 0
      fi
    done < <(find . -type f -name "$file_glob" -print0)

    if ${matched}; then
      return 1
    fi

    return 1
  fi
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

forbid_pattern() {
  local file_glob="$1"
  local pattern="$2"
  local label="$3"
  if search_in_repo_with_glob "$pattern" "$file_glob"; then
    fail "$label"
  else
    pass "$label"
  fi
}

echo "== Docs Consistency Checks =="

require_file "AGENTS.md" "Canonical agent guide"
require_file "PRD.md" "PRD"
require_file "spec.md" "System spec"
require_file "prompt.md" "Execution prompt"
require_file "specs/contracts.md" "Shared contracts spec"
require_file "specs/core.md" "Core component spec"
require_file "specs/helper-daemon.md" "Helper daemon component spec"
require_file "specs/menu-ui.md" "Menu UI component spec"
require_file "specs/backend-worker.md" "Backend worker component spec"
require_file "docs/vibe-coding-methodology.md" "Vibe coding methodology"
require_file "docs/eval-scorecard-template.md" "Eval scorecard template"
require_file ".github/copilot-instructions.md" "Copilot review instructions"

echo
echo "== Canonical Order Checks =="

require_pattern "AGENTS.md" "## Canonical Documents \\(Precedence\\)" "AGENTS contains precedence section"
require_pattern "AGENTS.md" "1\\. .*AGENTS\\.md" "AGENTS precedence lists AGENTS.md first"
require_pattern "AGENTS.md" "2\\. .*PRD\\.md" "AGENTS precedence lists PRD.md"
require_pattern "AGENTS.md" "3\\. .*spec\\.md" "AGENTS precedence lists spec.md"
require_pattern "AGENTS.md" "6\\. .*prompt\\.md" "AGENTS precedence lists prompt.md"

require_pattern "prompt.md" "## Mandatory First Step" "prompt contains mandatory first step"
require_pattern "prompt.md" "1\\. .*AGENTS\\.md" "prompt requires AGENTS.md"
require_pattern "prompt.md" "2\\. .*PRD\\.md" "prompt requires PRD.md"
require_pattern "prompt.md" "3\\. .*spec\\.md" "prompt requires spec.md"
require_pattern "prompt.md" "4\\. .*specs/contracts\\.md" "prompt requires specs/contracts.md"

echo
echo "== Section Coverage Checks =="

require_pattern "PRD.md" "^## 1\\. Problem Statement" "PRD has problem statement"
require_pattern "PRD.md" "^## 5\\. Scope and Support Matrix" "PRD has support matrix"
require_pattern "PRD.md" "^## 7\\. Functional Requirements" "PRD has functional requirements"
require_pattern "PRD.md" "^## 12\\. Launch Criteria \\(v1\\)" "PRD has launch criteria"

require_pattern "spec.md" "^## 6\\. Event Capture Model" "spec has event capture model"
require_pattern "spec.md" "^## 7\\. Office Adapter Behavior" "spec has office adapter behavior"
require_pattern "spec.md" "^## 13\\. XPC Contract Details" "spec has XPC contract"
require_pattern "spec.md" "^## 16\\. Test Matrix" "spec has test matrix"
require_pattern "spec.md" "Checkout Session|Checkout Sessions" "spec references Direct Checkout Sessions"
require_pattern "PRD.md" "verified sign-in" "PRD requires verified sign-in for Direct billing"
require_pattern "services-setup.md" "Worker-hosted pricing page|Worker-hosted pricing" "services setup documents Worker-hosted pricing"
require_pattern "AGENTS.md" "NSWorkspace" "AGENTS documents lifecycle capture"
require_pattern "PRD.md" "frontmost" "PRD documents frontmost refresh behavior"
require_pattern "spec.md" "1s.*power adapter|power adapter.*1s" "spec documents 1s AC refresh cadence"
require_pattern "spec.md" "10s.*battery|battery.*10s" "spec documents 10s battery refresh cadence"

echo
echo "== Component Mapping Checks =="

require_pattern "AGENTS.md" "specs/core\\.md" "AGENTS references core component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeCore/" "AGENTS maps core spec to source"
require_pattern "AGENTS.md" "specs/helper-daemon\\.md" "AGENTS references helper component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeHelper/" "AGENTS maps helper spec to source"
require_pattern "AGENTS.md" "specs/menu-ui\\.md" "AGENTS references menu component spec"
require_pattern "AGENTS.md" "Sources/OfficeResumeDirect/" "AGENTS maps menu spec to source"
require_pattern "AGENTS.md" "specs/backend-worker\\.md" "AGENTS references backend component spec"
require_pattern "AGENTS.md" "OfficeResumeBackend/" "AGENTS maps backend spec to source"
require_pattern "AGENTS.md" "Copilot Review Expectations" "AGENTS defines Copilot review expectations"
require_pattern ".github/pull_request_template.md" "Copilot review URL:" "PR template includes Copilot review URL field"

echo
echo "== Bundle Prefix Drift Checks =="

require_pattern "AGENTS.md" "com\\.pragprod\\.msofficeresume" "AGENTS uses current bundle prefix"
forbid_pattern "*.md" "com\\.alemira\\.msofficeresume|com\\.ilya\\.msofficeresume" "No stale bundle prefixes in markdown docs"

if ! search_in_repo_with_glob "com\\.pragprod\\.msofficeresume" "*.md"; then
  warn "No bundle prefix mentions found in markdown docs"
else
  pass "Current bundle prefix appears in markdown docs"
fi

echo
echo "== Direct Billing Drift Checks =="

forbid_pattern "*.md" "STRIPE_SUBSCRIBE_URL" "No stale STRIPE_SUBSCRIBE_URL references in markdown docs"
forbid_pattern "*.md" "Payment Link|Payment Links|shareable payment link" "No Payment Link terminology in markdown docs"
require_pattern "specs/backend-worker.md" "GET /billing/entry" "Backend spec documents billing entry endpoint"
require_pattern "specs/backend-worker.md" "GET /billing/pricing" "Backend spec documents pricing page endpoint"
require_pattern "specs/backend-worker.md" "POST /billing/checkout" "Backend spec documents checkout endpoint"
require_pattern "specs/menu-ui.md" "Choose Plan" "Menu UI spec documents Choose Plan action"
forbid_pattern_in_file "AGENTS.md" "AXObserver|Accessibility-first|prompt-accessibility" "AGENTS has no AX-specific capture contract"
forbid_pattern_in_file "PRD.md" "AXObserver|Accessibility-first|Accessibility: click to fix|Accessibility: OK" "PRD has no AX/Accessibility UI contract"
forbid_pattern_in_file "spec.md" "AXObserver|prompt Accessibility|Accessibility trust state" "spec has no AX-specific capture/XPC contract"
forbid_pattern_in_file "specs/contracts.md" "AXObserver|prompt-accessibility|Accessibility trust state" "contracts spec has no AX-specific IPC/status fields"
forbid_pattern_in_file "specs/helper-daemon.md" "AXObserver|prompt-accessibility|Accessibility trust state" "helper spec has no AX-specific runtime contract"
forbid_pattern_in_file "specs/menu-ui.md" "Accessibility: click to fix|Accessibility: OK" "menu UI spec has no Accessibility menu row"
forbid_pattern_in_file "prompt.md" "AXObserver|Accessibility-first" "implementation prompt has no AX-specific capture instructions"

echo
echo "== Summary =="
echo "Failures: $failures"
echo "Warnings: $warnings"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "Docs consistency checks passed."
