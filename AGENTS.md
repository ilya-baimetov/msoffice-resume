# Office Resume - Agent Guide

## Project Mission
Build and ship **Office Resume**, a direct-download macOS menu bar app plus helper that reliably restores Microsoft Office session state using an Accessibility-first external automation architecture.

## Canonical Documents (Precedence)
When documents conflict, apply this order:

1. `AGENTS.md` (this file): workflow and contributor guardrails.
2. `intent.md`: high-level product intent and framing.
3. `PRD.md`: product behavior, scope, user requirements, and release criteria.
4. `spec.md`: system-level architecture and implementation contract.
5. `specs/contracts.md`: shared cross-component interfaces and invariants.
6. `specs/*.md`: component-level implementation details.
7. `prompt.md`: execution prompt for fresh contexts/agents.

## Supporting Decision Docs
These are not above the canonical chain, but they explain the current product direction:
- `docs/direct-only-ax-decision-memo.md`
- `docs/direct-only-ax-migration-plan.md`

## Component Spec Map
- `specs/core.md` -> `Sources/OfficeResumeCore/**` and `Tests/OfficeResumeCoreTests/**`
- `specs/helper-daemon.md` -> `Sources/OfficeResumeHelper/**`
- `specs/menu-ui.md` -> `Sources/OfficeResumeDirect/**` and `Sources/MenuUIShared/**`
- `specs/backend-worker.md` -> `OfficeResumeBackend/**`

Legacy note:
- `Sources/OfficeResumeMAS/**` may remain in the repo during migration, but it is not part of the active v1 product contract.

## Locked Product Constraints
- Product name: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- Shipping channel: Direct download only
- Canonical artifact: signed/notarized `.pkg`
- Runtime model: menu bar app + embedded login-item helper
- Capture model:
  - primary: `AXObserver` / Accessibility notifications
  - secondary: `NSWorkspace` lifecycle/session notifications
  - tertiary: Office AppleScript / Apple Events for state resolution and restore execution
- Global restore policy: auto-restore on relaunch, one-shot per app launch instance
- Duplicate guard: reopen only missing documents/windows from the last snapshot
- Safety reconciliation:
  - no tight polling loop as the primary model
  - allow a sparse safety sweep only as documented in `spec.md`
- Retention: latest snapshot only (+ minimal local events/logs retained for 24 hours)
- Privacy: local logs only, no remote analytics
- Trial/pricing: 14-day trial, then `$5/month` or `$50/year`
- Offline entitlement grace: 7 days
- Direct trial and free-pass are server-authoritative after verified sign-in
- Debug and Release installs use the same entitlement path; no client-side entitlement bypass exists

## v1 Support Matrix
- Microsoft Word: full document-level capture/restore
- Microsoft Excel: full workbook-level capture/restore
- Microsoft PowerPoint: full presentation-level capture/restore
- Microsoft Outlook: limited mode (lifecycle capture; restore = relaunch only)
- Microsoft OneNote: explicitly unsupported in v1

## Product Direction
- `OfficeResumeDirect` is the only shipping target for v1.
- `OfficeResumeMAS` is deprecated and out of scope for the shipping contract.
- The product is intentionally no longer constrained by MAS sandbox/App Review compatibility.
- Accessibility permission is a required runtime dependency in v1 and must be treated as first-class product setup, not an implementation detail.

## Distribution and Billing Rules
`Office Resume` ships as a direct-download app:
- Stripe subscriptions (monthly/yearly) with 14-day trial enforced server-side
- Entitlement backend: unified `office-resume` Cloudflare Worker + D1/KV + Resend
- Auth flow: email magic link with app callback URL
- New purchases: Worker-hosted pricing page + Stripe Checkout Sessions after verified sign-in
- Existing paid subscribers: Stripe Billing Portal
- Free-pass allowlist is backend-authoritative only

Enterprise distribution is in scope for Direct:
- Developer ID signed + notarized `.pkg`
- compatible with MDM deployment and PPPC/TCC management

## Storage and IPC Policy
Use one direct-only shared root:
- `~/Library/Application Support/com.pragprod.msofficeresume/`

Shared directories under that root:
- `state/<officeBundleID>/snapshot-v1.json`
- `state/<officeBundleID>/events-v1.ndjson`
- `state/<officeBundleID>/unsaved-index-v1.json`
- `state/<officeBundleID>/unsaved/`
- `ipc/`
- `restore/`
- `logs/`
- `entitlements/`

Do not attempt to reverse-engineer Apple's private binary Resume formats exactly.

## Free-Pass and Entitlement Security Policy
- Free-pass is backend-authoritative in Direct and granted only via verified server-side allowlist/session checks.
- Keep a checked-in backend-side hard-coded allowlist file for real-world testing/friends-and-family access at `OfficeResumeBackend/src/free-pass-emails.js`; environment allowlist entries may extend it.
- Production release flow must not rely on client-side local free-pass files or environment overrides.
- Do not add client-side local entitlement or free-pass bypass paths.
- Direct session tokens are stored in Keychain during normal app usage.

## Coding and Architecture Guardrails
- Prefer Swift, SwiftUI/AppKit, and native Apple frameworks.
- Keep monitoring/restore logic in helper/shared core, not in UI layer.
- Keep adapters per Office app isolated behind protocols.
- Use `AXObserver` as the primary event source for app/window changes.
- Use `NSWorkspace` only for coarse lifecycle/session boundaries.
- Use Office scripting only to resolve canonical Office state and execute restore operations.
- Do not attempt to revive the sandboxed no-AX architecture.
- Do not depend on Office add-ins, VBA, or macros.
- Menu UI must use native `MenuBarExtra` menu style.
- The menu stays operational and includes Accessibility setup/status because AX is required.
- Billing/account details live in a compact shared account window, not in persistent menu rows.
- No remote telemetry in v1.
- Keep OneNote unsupported unless explicitly re-scoped in PRD/spec updates.
- Avoid slop/leftover code paths from the deprecated MAS-first architecture.

## Required Technical Components
- Menu bar app
- Embedded helper/login item daemon model
- XPC contract for settings/status/actions with shared IPC fallback
- AX observer layer for Office process/window events
- NSWorkspace lifecycle/session monitoring
- Office adapters (Word/Excel/PowerPoint/Outlook + unsupported OneNote stub)
- Snapshot persistence and restore engine
- Shared account/billing UI surface
- Direct entitlement provider + backend worker
- Local logs and status reporting
- Direct installer packaging flow (`.pkg` canonical)

## Build Modes
- `Debug` local build:
  - unsigned or ad hoc signed allowed
  - local testing uses the same downloaded-package install path and entitlement flow as ReleaseDirect
- `ReleaseDirect`:
  - Developer ID signed + notarized `.pkg`
  - production backend
  - no local bypass behavior

## Copilot Review Expectations
- Repository should include `.github/copilot-instructions.md` with risk-focused review guidance.
- Copilot review is advisory; static CI and regression checks remain merge gates.
- Code/spec changes should be reviewed against the canonical order in this file.
- Solo local workflow may rely on repo-managed git hooks plus local review before push; PRs remain optional for risky changes or when remote review history is desired.

## Testing and Acceptance Gate
No feature is complete unless these pass:

1. Unit tests for snapshot diffing, restore dedupe, one-shot markers, and entitlement grace logic.
2. Integration tests for AX event handling, adapter parsing/execution boundaries, and lifecycle-triggered capture flow behavior.
3. Backend tests for Direct auth, trial persistence, billing entry/Checkout/Billing Portal behavior, and free-pass allowlist enforcement.
4. Manual scenario checklist from `spec.md` test matrix.
5. Verification that trial expiration disables monitoring and restore while preserving read-only status.
6. Verification that OneNote remains unsupported.
7. Verification that no remote analytics endpoints are invoked.
8. Verification that Accessibility permission flow is required, works, and does not devolve into repeated prompt storms.
9. Verification that Apple Events consent is bounded and stable for the signed release build.
10. Verification that Direct pkg install upgrades previous Direct installs safely.
11. Verification that production Direct flow does not accept client-side free-pass or fake-session bypass.
12. Verification that Direct checkout requires verified sign-in and uses Worker-hosted Stripe Checkout Sessions.

## Contributor Workflow
1. Read `AGENTS.md`, `intent.md`, `PRD.md`, `spec.md`, `specs/contracts.md`, and relevant component specs before coding.
2. Update docs/specs first for behavior/architecture changes.
3. Implement in small vertical slices:
   - shared models/protocols
   - storage + event log + restore markers + logs
   - AX event substrate + helper state machine
   - adapters and restore engine
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
