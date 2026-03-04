# Eval Scorecard Template

Use this template to evaluate one implementation run (or one PR) against the docs-first methodology.

## Run Metadata
- Date:
- Evaluator:
- Branch:
- Commit SHA:
- Scope:
- Prompt/agent context used:

## Scoring Scale
- `0` = missing or contradictory
- `1` = partial / incomplete
- `2` = complete and testable

## A. Contract Eval (Pre-Code)

### A1. Contract Integrity
| Dimension | Score (0-2) | Evidence | Notes |
| --- | --- | --- | --- |
| Scope fidelity (AGENTS/PRD/spec aligned) |  |  |  |
| Requirement coverage (PRD -> spec traceability) |  |  |  |
| Architecture correctness (spec completeness) |  |  |  |
| Interface clarity (contracts and ownership) |  |  |  |
| Testability (explicit test matrix) |  |  |  |

### A2. Contract Checklist
- [ ] `AGENTS.md`, `PRD.md`, `spec.md`, `prompt.md` exist
- [ ] component specs exist for active components
- [ ] prompt requires reading canonical docs before coding
- [ ] unsupported scope is explicit
- [ ] locked constraints are explicit

## B. Implementation Eval

### B1. Build and Test Results
- `xcodebuild` (MAS):
- `xcodebuild` (Direct):
- Core tests:
- Backend tests (if applicable):
- Manual checklist pass/fail:

### B2. Implementation Quality
| Dimension | Score (0-2) | Evidence | Notes |
| --- | --- | --- | --- |
| Feature behavior matches PRD |  |  |  |
| Technical behavior matches spec |  |  |  |
| No silent scope expansion |  |  |  |
| Failure handling and logs |  |  |  |
| Operational readiness |  |  |  |

### B3. Key Findings
1.
2.
3.

## C. Regression Eval
| Dimension | Score (0-2) | Evidence | Notes |
| --- | --- | --- | --- |
| Existing behavior preserved |  |  |  |
| Docs updated with code changes |  |  |  |
| Component specs updated where needed |  |  |  |
| CI/automation status healthy |  |  |  |

## D. Numeric Summary
- Contract subtotal:
- Implementation subtotal:
- Regression subtotal:
- Total:
- Max possible:
- Percent:

## E. Gate Decision
- [ ] Pass (no dimension < 1, and total >= 80%)
- [ ] Fail

## F. Required Follow-Ups
1.
2.
3.

