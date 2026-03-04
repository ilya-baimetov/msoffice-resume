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
  if rg -q --pcre2 "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_pattern() {
  local file_glob="$1"
  local pattern="$2"
  local label="$3"
  if rg -q --pcre2 "$pattern" --glob "$file_glob" .; then
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

echo
echo "== Bundle Prefix Drift Checks =="

require_pattern "AGENTS.md" "com\\.pragprod\\.msofficeresume" "AGENTS uses current bundle prefix"
forbid_pattern "*.md" "com\\.alemira\\.msofficeresume|com\\.ilya\\.msofficeresume" "No stale bundle prefixes in markdown docs"

if ! rg -q "com\\.pragprod\\.msofficeresume" --glob "*.md" .; then
  warn "No bundle prefix mentions found in markdown docs"
else
  pass "Current bundle prefix appears in markdown docs"
fi

echo
echo "== Summary =="
echo "Failures: $failures"
echo "Warnings: $warnings"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "Docs consistency checks passed."
