# Office Resume v1 - Implementation Prompt

You are implementing **Office Resume v1** in this repository.

## Mandatory First Step
Before writing code, read these files in order and treat them as canonical:

1. `AGENTS.md`
2. `intent.md`
3. `PRD.md`
4. `spec.md`
5. `specs/contracts.md`
6. relevant component spec(s) in `specs/*.md` for the code you are changing

Do not start by re-planning the product. Execute the defined scope directly.

If implementing one component in isolation, load only:
- the canonical docs above
- that component spec
- directly referenced source files

Do not preload unrelated component specs.

## Objective
Build and maintain Office Resume as a Direct-only macOS runtime architecture optimized for reliable Office session restore.

v1 requirements:
- Word, Excel, and PowerPoint: document-level restore
- Outlook: limited relaunch-only support
- OneNote: unsupported
- 14-day trial
- `$5/month` and `$50/year`
- Stripe, Cloudflare Worker, and Resend for billing and auth

Capture strategy is locked:
- `AXObserver` or Accessibility notifications are the primary capture mechanism.
- `NSWorkspace` lifecycle and session notifications are secondary.
- Office scripting is tertiary and used only to resolve state and execute restore.
- A sparse frontmost safety sweep is allowed only as a backstop, not as the main event source.

Direct distribution strategy is locked:
- canonical artifact is a signed and notarized `.pkg`
- Accessibility permission is a first-class runtime dependency
- the shipping runtime is no longer constrained by MAS compatibility

Direct billing strategy is locked:
- verified email sign-in is required before purchase
- new Direct purchases use a Worker-hosted pricing page plus Stripe Checkout Sessions
- existing paid Direct subscribers use Stripe Billing Portal
- remaining Direct trial time is converted into Stripe-supported trial settings during Checkout

## Required Build Outputs
1. Xcode workspace and projects with `OfficeResumeDirect` as the shipping target
2. Shared core module for models, adapters, storage, restore engine, account and billing abstractions, and entitlement abstraction
3. Helper/login item process for monitoring and restore execution
4. XPC contract between menu app and helper
5. Cloudflare Worker backend for Direct auth, billing, and entitlement verification
6. Unit and integration tests covering key scenarios from the specs
7. Direct packaging scripts producing `.pkg` install artifacts for upgrade-friendly installs

## Implementation Order
1. Keep docs and specs aligned with changes before code edits.
2. Implement shared domain models and protocols from specs.
3. Implement direct-only storage and IPC rules.
4. Implement AX event substrate and helper state machine.
5. Implement Office adapters (Word, Excel, PowerPoint full; Outlook limited; OneNote unsupported).
6. Implement restore engine with dedupe and one-shot launch marker.
7. Implement unsaved temp artifact flow (force-save, index, purge).
8. Implement helper daemon with AX-driven capture and bounded reconciliation.
9. Implement shared menu bar UI controls and helper command flow.
10. Implement shared account window and Direct billing/auth providers.
11. Implement backend auth, webhook, entitlement, billing-entry, Checkout, and Billing-Portal endpoints.
12. Implement Direct `.pkg` packaging and update behavior.
13. Add or adjust tests and run the verification checklist from specs.

## Hard Constraints
- Keep scope aligned with `intent.md`, `PRD.md`, `spec.md`, and `specs/*.md`.
- Do not add remote analytics telemetry.
- Do not add OneNote restore in v1.
- Keep restore policy global and auto-on relaunch.
- Do not attempt to revive the deprecated no-AX sandbox architecture.
- Enforce post-trial inactive behavior: monitoring and restore disabled, history and status read-only.
- Enforce 7-day offline entitlement grace.
- Keep Debug and Release downloaded-package installs on the same runtime and entitlement path.

## Acceptance Criteria
Implementation is complete only when:
1. Direct target and helper build.
2. Helper, menu bar, and XPC or shared-IPC flow works.
3. AX-driven capture is functioning and Office scripting remains bounded and serialized.
4. Word, Excel, and PowerPoint restore works with dedupe.
5. Outlook relaunch-only behavior works.
6. OneNote remains unsupported without a dedicated menu row.
7. Direct billing and account flows exist.
8. Direct `.pkg` installer flow works for install and update.
9. Test matrix in `spec.md` is executed and results are reported.
10. Component specs are updated whenever component code changes.

## Response Format for Progress and Completion
When reporting progress:
- show what was implemented
- show which acceptance criteria are now satisfied
- show blockers or risk items

At final completion:
- provide a concise change summary
- provide test results (pass or fail with key outputs)
- provide remaining known gaps
