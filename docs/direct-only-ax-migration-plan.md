# Migration Plan - Current Helper To Direct-Only AX Architecture

## Goal
Move Office Resume from the current lifecycle-plus-scripting helper to a Direct-only, AX-first runtime without breaking Direct billing or local restore storage semantics any more than necessary.

## Non-Goals
- Do not preserve MAS as a v1 release target.
- Do not introduce Office add-ins, VBA, or macros.
- Do not rewrite the backend billing/auth model.
- Do not add cloud sync or telemetry.

## Migration Principles
- Docs first, code second.
- Keep restore engine and billing contracts stable where possible.
- Replace the capture substrate before deleting old logic.
- Bound user-visible permission churn during every phase.
- Prefer explicit deprecation of legacy MAS/sandbox paths over silent partial support.

## Phase 0 - Contract Reset
Deliverables:
- `intent.md`
- rewritten `PRD.md`
- rewritten `spec.md`
- updated component specs and guardrails
- decision memo and this migration plan

Exit criteria:
- canonical docs all agree that v1 is Direct-only and AX-first
- docs consistency checks enforce the new direction

## Phase 1 - Runtime And Packaging Baseline
Deliverables:
- direct-only release contract in build/docs/scripts
- stable Direct bundle IDs and helper identity
- Developer ID and notarization assumptions documented clearly
- remove primary reliance on sandbox/app-group packaging rules from the contract

Exit criteria:
- release docs and packaging scripts target Direct only
- permissions model is documented as AX + Apple Events, not sandbox folder grants

## Phase 2 - AX Event Substrate
Deliverables:
- per-process AX observer manager for Word, Excel, PowerPoint, and Outlook
- normalized app/window AX event mapping into helper mailbox work items
- attach/detach lifecycle bound to Office process discovery and termination

Exit criteria:
- helper can attach observers to supported running Office apps
- AX notifications drive capture scheduling without overlapping per-app work

## Phase 3 - Helper State Machine Refactor
Deliverables:
- explicit per-app runtime state machine
- per-app mailbox remains the serialization primitive
- launch, activate, deactivate, terminate, restore, and reconciliation all route through the same state machine
- recent-event logging becomes reason-tagged by trigger source (`ax`, `workspace`, `manual`, `reconcile`)

Exit criteria:
- no app-specific overlapping scripting work
- focus churn cannot create repeated prompt storms

## Phase 4 - Adapter And Restore Refactor
Deliverables:
- adapters become pure state resolvers and restore executors
- scripted fetch runs only after AX/lifecycle triggers and bounded reconciliation
- restore uses Launch Services first where appropriate, with app-specific scripted fallback only when necessary
- Outlook remains relaunch-only and is explicitly isolated from W/E/P logic

Exit criteria:
- W/E/P restore works from AX-scheduled captures
- no tight polling loop is needed as the main capture source

## Phase 5 - Menu And Permission UX
Deliverables:
- menu shows Accessibility state and remediation clearly
- menu keeps autostart, pause, restore, account, logs, and quit
- first-run and remediation copy are rewritten around AX being required
- repeated permission prompts are treated as regressions with explicit log markers

Exit criteria:
- signed test build shows bounded AX and Apple Events prompting
- menu accurately reflects permission and helper state

## Phase 6 - Legacy Path Removal
Deliverables:
- quarantine or remove deprecated no-AX helper logic
- quarantine or remove MAS-first assumptions from build/test acceptance gates
- remove sandbox-only storage and permission UX from active runtime docs and code
- keep legacy MAS code only if it is clearly marked deprecated and non-shipping

Exit criteria:
- no active v1 contract depends on MAS parity or no-AX capture
- review rules no longer protect obsolete runtime assumptions

## Phase 7 - Validation And Release Hardening
Deliverables:
- AX-focused manual test matrix for W/E/P relaunch, reboot, update, and crash scenarios
- TCC/permission churn checks for signed builds
- enterprise deployment notes for `.pkg` + PPPC/MDM
- release checklist updated to Direct-only shipping

Exit criteria:
- restore reliability is demonstrated on signed builds
- no repeated permission storms in normal operation
- Direct release path is ready for public and enterprise distribution

## Operational Notes
- The backend worker, trial, free-pass, Checkout Session, and Billing Portal flows should remain stable during this migration.
- The most dangerous transition area is not billing; it is the boundary between event capture and scripted state resolution.
- Avoid broad helper rewrites without preserving recent-event logging, because those logs are the fastest path to diagnosing Office-specific restore failures.
