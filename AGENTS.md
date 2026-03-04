# Office Resume - Agent Guide

## Project Mission
Build and ship **Office Resume**, a macOS menu bar app + helper that restores Microsoft Office session state reliably, with one unified runtime architecture across distribution channels and billing as the only intentional channel divergence.

## Canonical Documents (Precedence)
When documents conflict, apply this order:

1. `AGENTS.md` (this file): workflow and guardrails for contributors/agents.
2. `PRD.md`: product behavior, user requirements, scope, pricing, release criteria.
3. `spec.md`: system-level implementation contract and architecture.
4. `specs/contracts.md`: shared cross-component interfaces and invariants.
5. `specs/*.md`: component-level implementation details.
6. `prompt.md`: execution prompt for fresh contexts/agents.

## Component Spec Map
- `specs/core.md` -> `Sources/OfficeResumeCore/**` and `Tests/OfficeResumeCoreTests/**`
- `specs/helper-daemon.md` -> `Sources/OfficeResumeHelper/**`
- `specs/menu-ui.md` -> `Sources/OfficeResumeDirect/**`, `Sources/OfficeResumeMAS/**`, and `Sources/MenuUIShared/**`
- `specs/backend-worker.md` -> `OfficeResumeBackend/**`

## Locked Product Constraints
- Product name: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- UX: menu bar first, mostly automatic, quiet operation with local recent log visibility
- Startup: auto-start at login via helper (`SMAppService`)
- Capture model: Accessibility-first event interception (`AXObserver`) is required in v1
- Global restore policy: auto-restore on relaunch, one-shot per app launch instance
- Duplicate guard: open only missing documents during restore
- Polling fallback is removed in v1; capture is Accessibility event-driven only
- Retention: latest snapshot only (+ minimal local events/logs)
- Privacy: local logs only, no remote analytics
- Trial/pricing: 14-day trial, then `$5/month` or `$50/year`
- Offline entitlement grace: 7 days
- Canonical direct distribution artifact: `.pkg` installer with upgrade behavior

## v1 Support Matrix
- Microsoft Word: full document-level capture/restore
- Microsoft Excel: full workbook-level capture/restore
- Microsoft PowerPoint: full presentation-level capture/restore
- Microsoft Outlook: limited mode (capture lifecycle/window metadata; restore = relaunch only)
- Microsoft OneNote: explicitly unsupported in v1 (no dedicated menu row)

## Unification Policy
- MAS and Direct must share one runtime architecture for capture, restore, storage, helper IPC, UI behavior, and logging.
- Allowed channel-specific differences are limited to:
  - billing provider implementation
  - distribution/signing metadata required by channel
- Any non-billing divergence requires explicit PRD/spec update and approval.

## Distribution Channels and Billing Rules
Two targets/schemes remain in one codebase:

1. `OfficeResumeMAS`
- Mac App Store channel
- StoreKit 2 subscriptions (monthly/yearly) with 14-day trial
- App Sandbox, Apple Events constraints, and App Review risk handling

2. `OfficeResumeDirect`
- Direct channel
- Stripe subscriptions (monthly/yearly) with 14-day trial
- Entitlement backend: Cloudflare Worker + D1/KV
- Auth flow: email magic link

Cross-channel linking is not required in v1.

## Storage and IPC Policy
Use app-group-first storage/IPC conventions for both channels:

- Primary root per Office app:
  - `<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`
- Dev-only fallback (unsigned local runs only):
  - `~/Library/Application Support/com.pragprod.msofficeresume/...`

Per-app files:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `unsaved-index-v1.json`
- `unsaved/` (temp forced-save artifacts)

Do not attempt to reverse-engineer Apple's private binary Resume formats exactly.

## Free-Pass and Entitlement Security Policy
- Free-pass is backend-authoritative in Direct channel and granted only via verified server-side allowlist/session checks.
- Production release flow must not rely on client-side local free-pass files or environment overrides.
- Any local bypasses must be debug-only and explicitly gated for internal development.

## Coding and Architecture Guardrails
- Prefer Swift, SwiftUI/AppKit, and native Apple frameworks
- Keep monitoring/restore logic in helper/shared core, not in UI layer
- Keep adapters per Office app isolated behind protocols
- Use `AXObserver`/Accessibility notifications as the primary signal source for document/window transitions
- Menu UI must use native `MenuBarExtra` menu style; do not use `.menuBarExtraStyle(.window)` or custom popover/window menu UIs
- Keep MAS and Direct billing providers separated behind a common entitlement interface
- No remote telemetry in v1
- Keep OneNote unsupported unless explicitly re-scoped in PRD/spec updates
- Avoid slop/leftover code paths from previous channel-specific behavior

## Copilot Review Expectations
- Repository should include `.github/copilot-instructions.md` with risk-focused review guidance.
- PRs should request or auto-include Copilot review and triage findings.
- Copilot review is advisory; static CI and regression checks remain merge gates.

## Required Technical Components
- Menu bar app
- Login item helper daemon model
- XPC contract for settings/status/actions/events with shared IPC fallback
- Accessibility permission onboarding/status and AX observer lifecycle management
- Office adapters (Word/Excel/PowerPoint/Outlook + unsupported OneNote stub)
- Snapshot persistence and restore engine
- Entitlement providers (StoreKit 2 and Stripe)
- Local logs and status reporting
- Direct installer packaging flow (`.pkg` canonical)

## Testing and Acceptance Gate
No feature is complete unless these pass:

1. Unit tests for snapshot diffing, restore dedupe, one-shot markers, and entitlement grace logic.
2. Integration tests for adapter parsing/execution boundaries (mocked adapter execution plus AX-triggered capture flow checks).
3. Manual scenario checklist from `spec.md` test matrix.
4. Verification that trial expiration disables monitoring and restore while preserving read-only history.
5. Verification that OneNote remains unsupported.
6. Verification that no remote analytics endpoints are invoked.
7. Verification that behavior is correct with Accessibility both granted and denied.
8. Verification that Direct pkg install upgrades previous installs safely.
9. Verification that production Direct flow does not accept client-side local free-pass bypass.

## Contributor Workflow
1. Read `AGENTS.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, and relevant component specs before coding.
2. Update docs/specs first for behavior/architecture changes.
3. Implement in small vertical slices:
   - shared models/protocols
   - storage + event log
   - adapters
   - restore engine
   - helper and XPC
   - menu UI
   - billing/entitlements
   - packaging/CI
4. Keep component specs synchronized with code changes in the same PR.
5. Run docs consistency and automated checks before opening/merging PR.
