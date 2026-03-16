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

If implementing one component in isolation, load only:
- canonical docs above
- that component spec
- directly referenced source files

Do not preload unrelated component specs.

## Objective
Build and maintain Office Resume as a unified macOS runtime architecture where MAS and Direct differ only by billing/auth provider and channel-required distribution metadata.

v1 requirements:
- Word/Excel/PowerPoint: document-level restore
- Outlook: limited relaunch-only support
- OneNote: unsupported (no dedicated menu row)
- 14-day trial
- `$5/month` and `$50/year`
- StoreKit 2 for MAS
- Stripe + Cloudflare Worker + Resend for Direct

Capture strategy is locked:
- Accessibility (`AXObserver`) is the primary event interception mechanism.
- Polling fallback is removed in v1.

Direct distribution strategy is locked:
- Canonical Direct installer is a standard `.pkg` that upgrades prior Direct installs.

Free-pass strategy is locked:
- Backend-authoritative allowlist only for Direct.
- Production app must not grant free-pass from local file/env overrides.
- The backend may keep a checked-in hard-coded allowlist file for friends-and-family testing.

Direct billing strategy is locked:
- verified email sign-in is required before purchase
- new Direct purchases use a Worker-hosted pricing page plus Stripe Checkout Sessions
- existing paid Direct subscribers use Stripe Billing Portal
- remaining Direct trial time is converted into Stripe-supported trial settings during Checkout

## Required Build Outputs
1. Xcode workspace/projects with two app targets/schemes:
- `OfficeResumeMAS`
- `OfficeResumeDirect`
2. Shared core module for models, adapters, storage, restore engine, account/billing abstractions, and entitlement abstraction.
3. Helper/login item process for monitoring and restore execution.
4. XPC contract between menu app and helper.
5. Cloudflare Worker backend for direct auth + entitlement verification.
6. Unit/integration tests covering key scenarios from specs.
7. Direct packaging scripts producing `.pkg` install artifacts for upgrade-friendly installs.

## Implementation Order
1. Keep docs/specs aligned with changes before code edits.
2. Implement shared domain models/protocols from specs.
3. Implement unified app-group-first storage and IPC fallback rules.
4. Implement Office adapters (W/E/P full, Outlook limited, OneNote unsupported).
5. Implement restore engine with dedupe + one-shot launch marker.
6. Implement unsaved temp artifact flow (force-save, index, purge).
7. Implement helper daemon with `NSWorkspace` lifecycle + `AXObserver` capture.
8. Implement shared menu bar UI controls and helper command flow.
9. Implement shared account window and billing/account providers.
10. Implement backend auth/webhook/entitlement/billing-entry/Checkout/Billing-Portal endpoints.
11. Implement Direct `.pkg` packaging and update behavior.
12. Add/adjust tests and run verification checklist from specs.

## Hard Constraints
- Keep scope aligned with `PRD.md`, `spec.md`, and `specs/*.md`.
- Do not add remote analytics telemetry.
- Do not add OneNote restore in v1.
- Keep restore policy global and auto-on relaunch.
- Surface Accessibility permission status in UI and degrade gracefully when not granted.
- Enforce post-trial inactive behavior: monitoring + restore disabled, history/status read-only.
- Enforce 7-day offline entitlement grace.
- Keep non-billing behavior unified across MAS and Direct.
- Keep Debug-only shortcuts compile-time gated and runtime opt-in only.

## Acceptance Criteria
Implementation is complete only when:
1. Both targets build.
2. Helper + menu bar + XPC/shared-IPC flow works.
3. Accessibility-first capture is functioning.
4. W/E/P restore works with dedupe.
5. Outlook relaunch-only behavior works.
6. OneNote remains unsupported without dedicated menu row.
7. Billing/account flows exist for MAS and Direct.
8. Direct `.pkg` installer flow works for install and update.
9. Test matrix in `spec.md` is executed and results are reported.
10. Component specs are updated whenever component code changes.

## Response Format for Progress and Completion
When reporting progress:
- Show what was implemented.
- Show which acceptance criteria are now satisfied.
- Show blockers/risk items.

At final completion:
- Provide concise change summary.
- Provide test results (pass/fail with key outputs).
- Provide remaining known gaps.
