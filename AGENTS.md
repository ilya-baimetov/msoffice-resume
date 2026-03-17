# Office Resume - Agent Guide

## Project Mission
Build and ship **Office Resume**, a macOS menu bar app plus helper that restores Microsoft Office session state reliably, with one unified runtime across distribution channels and billing as the only intentional channel divergence.

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
- UX: menu bar first, mostly automatic, quiet operation with local log visibility
- Startup: auto-start at login via helper (`SMAppService`)
- Capture model: Accessibility-first event interception (`AXObserver`) is required in v1
- Global restore policy: auto-restore on relaunch, one-shot per app launch instance
- Duplicate guard: open only missing documents during restore
- Polling fallback is removed in v1; capture is Accessibility event-driven only
- Retention: latest snapshot only (+ minimal local events/logs)
- Privacy: local logs only, no remote analytics
- Trial/pricing: 14-day trial, then `$5/month` or `$50/year`
- Offline entitlement grace: 7 days
- Canonical direct artifact: `.pkg` installer with upgrade behavior
- Direct trial and free-pass are server-authoritative after verified sign-in
- Debug local testing remains supported through explicit debug-only runtime opt-in

## v1 Support Matrix
- Microsoft Word: full document-level capture/restore
- Microsoft Excel: full workbook-level capture/restore
- Microsoft PowerPoint: full presentation-level capture/restore
- Microsoft Outlook: limited mode (capture lifecycle/window metadata; restore = relaunch only)
- Microsoft OneNote: explicitly unsupported in v1 (no dedicated menu row)

## Unification Policy
- MAS and Direct must share one runtime architecture for capture, restore, storage, helper IPC, UI behavior, logging, and packaging shape.
- Allowed channel-specific differences are limited to:
  - billing/auth provider implementation
  - channel-required signing/distribution metadata
- Any non-billing divergence requires explicit PRD/spec update and approval.

## Distribution Channels and Billing Rules
Two targets/schemes remain in one codebase:

1. `OfficeResumeMAS`
- Mac App Store channel
- StoreKit 2 subscriptions (monthly/yearly) with 14-day trial configured in App Store Connect
- App Sandbox, Apple Events constraints, and App Review risk handling

2. `OfficeResumeDirect`
- Direct channel
- Stripe subscriptions (monthly/yearly) with 14-day trial enforced server-side
- Entitlement backend: Cloudflare Worker + D1/KV + Resend
- Auth flow: email magic link with app callback URL
- New purchases: Worker-hosted pricing page + Stripe Checkout Sessions after verified sign-in
- Existing paid subscribers: Stripe Billing Portal
- Free-pass allowlist is backend-authoritative only

Cross-channel linking is not required in v1.

## Storage and IPC Policy
Use app-group-first storage/IPC conventions for both channels:

- Primary root:
  - `<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`
- Shared auxiliary directories under the same app-group-or-debug-fallback root:
  - `ipc/`
  - `restore/`
  - `logs/`
  - `entitlements/`
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
- Keep a checked-in backend-side hard-coded allowlist file for real-world testing/friends-and-family access; environment allowlist entries may extend it.
- Production release flow must not rely on client-side local free-pass files or environment overrides.
- Any local bypasses must be debug-only, explicitly gated, and absent from Release behavior.
- Direct session tokens are stored in Keychain during normal app usage.

## Coding and Architecture Guardrails
- Prefer Swift, SwiftUI/AppKit, and native Apple frameworks.
- Keep monitoring/restore logic in helper/shared core, not in UI layer.
- Keep adapters per Office app isolated behind protocols.
- Use `AXObserver`/Accessibility notifications as the primary signal source for document/window transitions.
- Menu UI must use native `MenuBarExtra` menu style.
- The menu stays lean: helper connection, autostart health, Accessibility health, pause/resume, restore now, advanced actions, account entry point, quit.
- Billing/account details live in a compact shared account window, not in persistent menu rows.
- Keep MAS and Direct billing providers separated behind shared account/entitlement interfaces.
- No remote telemetry in v1.
- Keep OneNote unsupported unless explicitly re-scoped in PRD/spec updates.
- Avoid slop/leftover code paths from previous channel-specific behavior.

## Required Technical Components
- Menu bar app
- Embedded helper/login item daemon model
- XPC contract for settings/status/actions with shared IPC fallback
- Accessibility permission onboarding/status and AX observer lifecycle management
- Office adapters (Word/Excel/PowerPoint/Outlook + unsupported OneNote stub)
- Snapshot persistence and restore engine
- Shared account/billing UI surface
- Entitlement providers (StoreKit 2 and Stripe)
- Local logs and status reporting
- Direct installer packaging flow (`.pkg` canonical)

## Build Modes
- `Debug` local build:
  - unsigned allowed
  - local testing supported
  - debug-only auth/entitlement shortcuts may be available behind compile-time guards plus explicit runtime opt-in
- `ReleaseDirect`:
  - signed/notarized `.pkg`
  - production backend
  - no local bypass behavior
- `ReleaseMAS`:
  - App Store build using StoreKit + App Store Connect

## Copilot Review Expectations
- Repository should include `.github/copilot-instructions.md` with risk-focused review guidance.
- If a PR is used, it should request or auto-include Copilot review and findings triage.
- Copilot review is advisory; static CI and regression checks remain merge gates.
- Code/spec changes should be reviewed against the canonical order in this file.
- Solo local workflow may rely on repo-managed git hooks plus local review before push; PRs remain optional for risky changes or when remote review history is desired.

## Testing and Acceptance Gate
No feature is complete unless these pass:

1. Unit tests for snapshot diffing, restore dedupe, one-shot markers, optional-path handling, and entitlement grace logic.
2. Integration tests for adapter parsing/execution boundaries and AX-triggered capture flow behavior.
3. Backend tests for Direct auth, trial persistence, billing entry/Checkout/Billing Portal behavior, and free-pass allowlist enforcement.
4. Manual scenario checklist from `spec.md` test matrix.
5. Verification that trial expiration disables monitoring and restore while preserving read-only status.
6. Verification that OneNote remains unsupported.
7. Verification that no remote analytics endpoints are invoked.
8. Verification that behavior is correct with Accessibility both granted and denied.
9. Verification that Direct pkg install upgrades previous Direct installs safely and blocks MAS/Direct conflict.
10. Verification that production Direct flow does not accept client-side free-pass or fake-session bypass.
11. Verification that Direct checkout requires verified sign-in and uses Worker-hosted Stripe Checkout Sessions.

## Contributor Workflow
1. Read `AGENTS.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, and relevant component specs before coding.
2. Update docs/specs first for behavior/architecture changes.
3. Implement in small vertical slices:
   - shared models/protocols
   - storage + event log + restore markers + logs
   - adapters
   - restore engine
   - helper and XPC/shared IPC
   - menu/account UI
   - billing/entitlements/backend
   - packaging/CI
4. Keep component specs synchronized with code changes in the same change set.
5. Install repo-managed git hooks on each workstation: `./scripts/install-git-hooks.sh`.
6. Default solo workflow:
   - edit
   - local review
   - commit
   - repeat
   - push only after local hooks and full checks pass
7. Use a PR only when you want GitHub/Copilot review history or an extra merge gate.
8. Run docs consistency, builds, tests, and audit checks before pushing or merging.
