# Office Resume - Agent Guide

## Project Mission
Build and ship **Office Resume**, a macOS menu bar app + helper that captures Microsoft Office session state and restores it on relaunch with behavior close to native macOS Resume.

This repository is documentation-first at this stage. Implementation work must follow the requirements and constraints in the canonical documents below.

## Canonical Documents (Precedence)
When documents conflict, apply this order:

1. `AGENTS.md` (this file): workflow and guardrails for contributors/agents.
2. `PRD.md`: product behavior, user requirements, scope, pricing, release criteria.
3. `spec.md`: implementation details, APIs/contracts, storage format, test matrix.
4. `prompt.md`: execution prompt for fresh contexts/agents.

## Locked Product Constraints
- Product name: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- UX: menu bar first, mostly automatic, quiet operation with local recent log visibility
- Startup: auto-start at login via helper (`SMAppService`)
- Global restore policy: auto-restore on relaunch, one-shot per app launch instance
- Duplicate guard: open only missing documents during restore
- Polling options: `1s`, `5s`, `15s` (default), `1m`, `None`
- Retention: latest snapshot only (+ minimal local events/logs)
- Privacy: local logs only, no remote analytics
- Trial/pricing: 14-day trial, then `$5/month` or `$50/year`
- Offline entitlement grace: 7 days

## v1 Support Matrix
- Microsoft Word: full document-level capture/restore
- Microsoft Excel: full workbook-level capture/restore
- Microsoft PowerPoint: full presentation-level capture/restore
- Microsoft Outlook: limited mode (capture lifecycle/window metadata; restore = relaunch only)
- Microsoft OneNote: explicitly unsupported in v1 (must be shown as unsupported in UI/help)

## Distribution Channels and Billing Rules
Two targets/schemes in one codebase:

1. `OfficeResumeMAS`
- Mac App Store first
- StoreKit 2 subscriptions (monthly/yearly) with 14-day trial
- App Sandbox and Apple Events constraints apply
- May require temporary Apple Events exceptions for Office targets

2. `OfficeResumeDirect`
- Direct distribution fallback
- Stripe subscriptions (monthly/yearly) with 14-day trial
- Entitlement backend: Cloudflare Worker + D1/KV
- Auth flow: email magic link

Cross-channel linking is not required in v1.

## Storage Policy
Use native-like saved-state location conventions with a documented custom schema:

- Direct build root per Office app:
  - `~/Library/Saved Application State/<officeBundleID>.savedState/OfficeResume/`
- MAS build root per Office app:
  - app-group container mirror path with equivalent subfolder layout

Per-app files:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `unsaved-index-v1.json`
- `unsaved/` (temp forced-save artifacts)

Do not attempt to reverse-engineer or emulate Apple's private binary Resume formats exactly.

## Unsaved Document Policy
For Word/Excel/PowerPoint untitled docs:

- Force-save periodically to temp artifacts in the per-app storage path
- Persist metadata linking artifact to origin app/session/doc context
- Reopen artifacts during restore when applicable
- Purge artifacts once no longer needed by the latest active snapshot lifecycle
- Side effect is accepted: untitled docs can become saved temp files with changed title/path

## Coding and Architecture Guardrails
- Prefer Swift, SwiftUI/AppKit, and native Apple frameworks
- Keep monitoring/restore logic in helper/shared core, not in UI layer
- Keep adapters per Office app isolated behind protocols
- Keep MAS and Direct billing providers separated behind a common entitlement interface
- No remote telemetry in v1
- Keep OneNote unsupported unless explicitly re-scoped in PRD/spec updates
- Do not broaden scope without explicit updates to `PRD.md` and `spec.md`

## Required Technical Components
- Menu bar app
- Login item helper daemon model
- XPC contract for settings/status/actions/events
- Office adapters (Word/Excel/PowerPoint/Outlook + unsupported OneNote stub)
- Snapshot persistence and restore engine
- Entitlement providers (StoreKit 2 and Stripe)
- Local logs and status reporting

## Testing and Acceptance Gate
No feature is complete unless these pass:

1. Unit tests for snapshot diffing, restore dedupe, one-shot markers, and entitlement grace logic.
2. Integration tests for adapter parsing/execution boundaries (mocked AppleScript and real-script smoke tests where feasible).
3. Manual scenario checklist from `spec.md` test matrix.
4. Verification that trial expiration disables monitoring and restore while preserving read-only history.
5. Verification that OneNote is surfaced as unsupported.
6. Verification that no remote analytics endpoints are invoked.

## Contributor Workflow
1. Read `AGENTS.md`, `PRD.md`, and `spec.md` before coding.
2. Implement in small vertical slices:
   - shared models/protocols
   - storage + event log
   - adapters
   - restore engine
   - helper and XPC
   - menu UI
   - billing/entitlements
3. Keep docs current when behavior or interfaces change.
4. For any scope change request, update `PRD.md` and `spec.md` in the same change set.
