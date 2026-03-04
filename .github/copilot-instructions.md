# Copilot Code Review Instructions

## Mission
Prioritize correctness, safety, regression prevention, and spec adherence over style-only feedback.

## Severity Model
Use this triage order in findings:
1. `High`: data loss/security/entitlement bypass/crash risk/user-visible restore corruption
2. `Medium`: functional regressions, correctness drift, installer/update breakage, IPC reliability
3. `Low`: maintainability issues likely to cause future bugs
4. Avoid pure style nits unless they materially improve correctness or maintainability

## Critical Invariants (Must Protect)
1. Restore dedupe + one-shot marker correctness
- Never reopen already-open docs
- Never repeat restore in same launch instance

2. Snapshot/unsaved artifact safety
- No data-loss behavior
- Force-saved artifact lifecycle remains consistent and purge-safe

3. Entitlement security
- Production Direct must not accept local free-pass file/env bypasses
- Free-pass must be backend-authoritative via verified session identity

4. Channel parity
- MAS and Direct runtime behavior must remain unified except billing provider/channel metadata

5. Privacy
- No remote analytics/telemetry introduced in app/helper/backend accidentally

6. Installer/update reliability
- Direct `.pkg` install/upgrade path must preserve launch behavior and avoid orphaned process state

## Risk-Ranked Focus Areas
Review these first, in order:
1. Entitlement and free-pass logic (`Sources/OfficeResumeCore/Entitlements.swift`, `OfficeResumeBackend/src/**`)
2. Restore correctness (`RestoreEngine`, adapter restore flows, one-shot markers)
3. Helper/menu command transport (XPC + shared IPC fallback)
4. Accessibility trust and observer lifecycle
5. Packaging scripts (`scripts/release-direct.sh`, pkg scripts, postinstall behavior)
6. Spec/documentation synchronization with code changes

## Spec Alignment Contract
When code changes touch a component, verify matching spec updates are present:
- Core: `spec.md`, `specs/contracts.md`, `specs/core.md`
- Helper: `spec.md`, `specs/contracts.md`, `specs/helper-daemon.md`
- Menu/UI: `spec.md`, `specs/contracts.md`, `specs/menu-ui.md`
- Backend: `spec.md`, `specs/contracts.md`, `specs/backend-worker.md`

Canonical precedence:
1. `AGENTS.md`
2. `PRD.md`
3. `spec.md`
4. `specs/contracts.md`
5. `specs/*.md`
6. `prompt.md`

## Comment Quality Rules
Each non-trivial finding should include:
1. What is wrong (specific behavior)
2. Why it matters (user/system impact)
3. Where it occurs (file + narrow line scope)
4. How to reproduce/validate quickly
5. Suggested fix direction (concise)

Avoid:
- generic comments without impact
- repetitive “consider refactor” notes with no concrete risk
- style-only nit spam

## Diff Hotspots to Always Inspect
- `Sources/OfficeResumeCore/**`
- `Sources/OfficeResumeHelper/**`
- `Sources/MenuUIShared/**`
- `Sources/OfficeResumeDirect/**`
- `Sources/OfficeResumeMAS/**`
- `OfficeResumeBackend/**`
- `scripts/**`
- `AGENTS.md`, `PRD.md`, `spec.md`, `specs/*.md`

## Output Expectations
1. List high-severity findings first.
2. Group by severity, then file.
3. Include explicit `No high/medium findings` statement when applicable.
4. Call out residual risk/testing gaps even when no blocking issues found.
