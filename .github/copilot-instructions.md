# Copilot Code Review Instructions

## Mission
Prioritize correctness, safety, regression prevention, and spec adherence over style-only feedback.

## Severity Model
Use this triage order in findings:
1. `High`: data loss, security, entitlement bypass, repeated prompt storms, crash risk, user-visible restore corruption
2. `Medium`: functional regressions, correctness drift, installer or update breakage, IPC reliability
3. `Low`: maintainability issues likely to cause future bugs
4. Avoid pure style nits unless they materially improve correctness or maintainability

## Critical Invariants (Must Protect)
1. Restore dedupe and one-shot marker correctness
- never reopen already-open docs
- never repeat restore in the same launch instance

2. Snapshot and unsaved artifact safety
- no data-loss behavior
- force-saved artifact lifecycle remains consistent and purge-safe

3. Entitlement security
- production Direct must not accept local free-pass file or env bypasses
- free-pass must be backend-authoritative via verified session identity

4. AX and Apple Events reliability
- AX is the primary event source
- Apple Events work must be serialized per app
- no repeated Accessibility or Apple Events prompt storms

5. Privacy
- no remote analytics or telemetry introduced in app, helper, or backend accidentally

6. Installer and update reliability
- Direct `.pkg` install and upgrade path must preserve launch behavior and avoid orphaned process state

## Risk-Ranked Focus Areas
Review these first, in order:
1. Entitlement and free-pass logic (`Sources/OfficeResumeCore/Entitlements.swift`, `OfficeResumeBackend/src/**`)
2. Restore correctness (`RestoreEngine`, adapter restore flows, one-shot markers)
3. Helper AX lifecycle, per-app mailbox serialization, and prompt-bounding logic
4. Helper and menu command transport (XPC plus shared IPC fallback)
5. Packaging scripts (`scripts/release-direct.sh`, pkg scripts, postinstall behavior)
6. Spec and documentation synchronization with code changes

## Spec Alignment Contract
When code changes touch a component, verify matching spec updates are present:
- Core: `intent.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, `specs/core.md`
- Helper: `intent.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, `specs/helper-daemon.md`
- Menu/UI: `intent.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, `specs/menu-ui.md`
- Backend: `intent.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, `specs/backend-worker.md`

Canonical precedence:
1. `AGENTS.md`
2. `intent.md`
3. `PRD.md`
4. `spec.md`
5. `specs/contracts.md`
6. `specs/*.md`
7. `prompt.md`

## Comment Quality Rules
Each non-trivial finding should include:
1. what is wrong
2. why it matters
3. where it occurs (file plus narrow line scope)
4. how to reproduce or validate quickly
5. suggested fix direction

Avoid:
- generic comments without impact
- repetitive refactor notes with no concrete risk
- style-only nit spam

## Diff Hotspots To Always Inspect
- `Sources/OfficeResumeCore/**`
- `Sources/OfficeResumeHelper/**`
- `Sources/MenuUIShared/**`
- `Sources/OfficeResumeDirect/**`
- `OfficeResumeBackend/**`
- `scripts/**`
- `AGENTS.md`, `intent.md`, `PRD.md`, `spec.md`, `specs/*.md`

## Output Expectations
1. List high-severity findings first.
2. Group by severity, then file.
3. Include an explicit `No high/medium findings` statement when applicable.
4. Call out residual risk and testing gaps even when no blocking issues are found.
