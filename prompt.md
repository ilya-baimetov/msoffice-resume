# Office Resume v1 - Implementation Prompt

You are implementing **Office Resume v1** in this repository.

## Mandatory First Step
Before writing code, read these files in order and treat them as canonical:

1. `AGENTS.md`
2. `PRD.md`
3. `spec.md`

Do not start by re-planning the product. Execute the defined scope directly.

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

## Required Build Outputs
1. Xcode workspace/projects with two app targets/schemes:
- `OfficeResumeMAS`
- `OfficeResumeDirect`
2. Shared core module for models, adapters, storage, restore engine, and entitlement abstraction.
3. Helper/login item process for monitoring and restore execution.
4. XPC contract between menu app and helper.
5. Cloudflare Worker backend for direct entitlement verification (Stripe webhook + auth flow).
6. Unit/integration tests covering key scenarios from `spec.md`.

## Implementation Order
1. Create project structure and targets/schemes.
2. Implement shared domain models/protocols from `spec.md`.
3. Implement storage layer and snapshot/event schemas.
4. Implement Office adapters (W/E/P full, Outlook limited, OneNote unsupported).
5. Implement restore engine with dedupe + one-shot launch marker.
6. Implement unsaved temp artifact flow (force-save, index, purge).
7. Implement helper daemon with polling + NSWorkspace lifecycle capture.
8. Implement XPC interface and menu bar UI controls.
9. Implement entitlement providers:
- StoreKit 2 (MAS)
- Stripe API client (direct)
10. Implement Cloudflare Worker endpoints and Stripe webhook handling.
11. Add tests and run verification checklist.

## Hard Constraints
- Keep scope exactly aligned with `PRD.md` and `spec.md`.
- Do not add remote analytics telemetry.
- Do not add OneNote restore in v1.
- Keep restore policy global and auto-on relaunch.
- Keep polling selector values exactly: `1s`, `5s`, `15s`, `1m`, `None`.
- Enforce post-trial inactive behavior: monitoring + restore disabled, history read-only.
- Enforce 7-day offline entitlement grace.

## Acceptance Criteria
Implementation is complete only when:
1. Both targets build.
2. Helper + menu bar + XPC flow works.
3. W/E/P restore works with dedupe.
4. Outlook relaunch-only behavior works.
5. OneNote unsupported state is visible.
6. Billing flows exist for MAS and direct channels.
7. Test matrix in `spec.md` is executed and results are reported.

## Response Format for Progress and Completion
When reporting progress:
- Show what was implemented.
- Show which acceptance criteria are now satisfied.
- Show any blockers/risk items.

At final completion:
- Provide a concise change summary.
- Provide test results (pass/fail with key outputs).
- Provide remaining known gaps, if any.
