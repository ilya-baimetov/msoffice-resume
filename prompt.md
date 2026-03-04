# Office Resume v1 - Implementation Prompt

You are implementing **Office Resume v1** in this repository.

## Mandatory First Step
Before writing code, read these files in order and treat them as canonical:

1. `AGENTS.md`
2. `PRD.md`
3. `spec.md`
4. `specs/contracts.md`
5. Relevant component spec(s) in `specs/*.md` for the code you are changing

Do not start by re-planning the product. Execute the defined scope directly.

If you are implementing one component in isolation, load only:
- canonical docs above
- that component spec
- directly referenced source files

Do not preload unrelated component specs.

## Objective
Build a macOS 14+ Apple Silicon menu bar app with a login helper daemon that captures Office state and restores it on relaunch, including:
- Word/Excel/PowerPoint document-level restore
- Outlook limited relaunch-only support
- OneNote unsupported status in UI
- Trial + subscription model:
  - 14-day trial
  - `$5/month` or `$50/year`
  - StoreKit 2 for MAS target
  - Stripe + Cloudflare Worker entitlement service for direct target

Capture strategy is locked:
- Accessibility (`AXObserver`) is the primary event-interception mechanism for Office window/document transitions.
- Polling fallback is removed in v1.

## Required Build Outputs
1. Xcode workspace/projects with two app targets/schemes:
- `OfficeResumeMAS`
- `OfficeResumeDirect`
2. Shared core module for models, adapters, storage, restore engine, and entitlement abstraction.
3. Helper/login item process for monitoring and restore execution.
4. XPC contract between menu app and helper.
5. Cloudflare Worker backend for direct entitlement verification (Stripe webhook + auth flow).
6. Unit/integration tests covering key scenarios from `spec.md` and component specs.

## Implementation Order
1. Create project structure and targets/schemes.
2. Implement shared domain models/protocols from `spec.md` + `specs/contracts.md`.
3. Implement storage layer and snapshot/event schemas.
4. Implement Office adapters (W/E/P full, Outlook limited, OneNote unsupported).
5. Implement restore engine with dedupe + one-shot launch marker.
6. Implement unsaved temp artifact flow (force-save, index, purge).
7. Implement helper daemon with `NSWorkspace` lifecycle capture + Accessibility observer interception.
8. Implement XPC interface and menu bar UI controls.
9. Implement entitlement providers:
- StoreKit 2 (MAS)
- Stripe API client (direct)
10. Implement Cloudflare Worker endpoints and Stripe webhook handling.
11. Add tests and run verification checklist from `spec.md` and component specs.

## Hard Constraints
- Keep scope exactly aligned with `PRD.md`, `spec.md`, and `specs/*.md`.
- Do not add remote analytics telemetry.
- Do not add OneNote restore in v1.
- Keep restore policy global and auto-on relaunch.
- Surface Accessibility permission status in UI and degrade gracefully when not granted.
- Enforce post-trial inactive behavior: monitoring + restore disabled, history read-only.
- Enforce 7-day offline entitlement grace.

## Acceptance Criteria
Implementation is complete only when:
1. Both targets build.
2. Helper + menu bar + XPC flow works.
3. Accessibility-first capture is functioning.
4. W/E/P restore works with dedupe.
5. Outlook relaunch-only behavior works.
6. OneNote unsupported state is visible.
7. Billing flows exist for MAS and direct channels.
8. Test matrix in `spec.md` is executed and results are reported.
9. If component code changed, the matching component spec is updated.

## Response Format for Progress and Completion
When reporting progress:
- Show what was implemented.
- Show which acceptance criteria are now satisfied.
- Show any blockers/risk items.

At final completion:
- Provide a concise change summary.
- Provide test results (pass/fail with key outputs).
- Provide remaining known gaps, if any.
