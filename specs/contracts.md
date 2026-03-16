# Shared Contracts

This file defines cross-component interfaces and invariants.

## Locked Global Constraints
- Product: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- Capture strategy: Accessibility-first (`AXObserver`) + lifecycle notifications
- Polling fallback: not used in v1
- Runtime behavior parity across MAS/Direct except billing/auth provider internals

## Shared Domain Types
- `OfficeApp`: `word`, `excel`, `powerpoint`, `outlook`, `onenote`
- `DocumentSnapshot`: `app`, `displayName`, `canonicalPath?`, `isSaved`, `isTempArtifact`, `capturedAt`
- `AppSnapshot`: `app`, `launchInstanceID`, `capturedAt`, `documents`, `windowsMeta`
- `LifecycleEvent`: `app`, `type`, `timestamp`, `details`
- `EntitlementState`: `isActive`, `plan`, `validUntil`, `trialEndsAt`, `lastValidatedAt`
- `BillingAction`: `kind` (`subscribe` or `manageSubscription`) and user-facing title
- `AccountState`: signed-in email or `nil`, current entitlement snapshot, optional billing action, sign-in/sign-out availability flags, optional status message

## XPC Contract (Menu <-> Helper)
- Transport:
  - preferred: XPC request/reply for status + commands
  - required fallback: shared IPC status file + distributed command notifications
- `getStatus()`
- `setPaused(Bool)`
- `restoreNow(app?)`
- `clearSnapshot(app?)`

Required shared IPC fallback commands:
- `pause`
- `restore-now`
- `clear-snapshot`
- `refresh-entitlement`
- `prompt-accessibility`
- `quit-helper`

Status payload must include:
- `isPaused`, `helperRunning`
- entitlement state summary
- Accessibility trust state
- per-app latest snapshot timestamps
- unsupported apps list

## Storage Contract
Per Office app under unified root policy:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `unsaved-index-v1.json`
- `unsaved/`

Shared auxiliary files under the same root policy:
- `ipc/daemon-status-v1.json`
- `ipc/daemon-xpc-endpoint-v1.data`
- `restore/restore-markers-v1.json`
- `logs/debug-v1.log`
- `entitlements/entitlement-cache-v1.json`

Primary root (MAS + Direct signed runs):
- `<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

Dev-only fallback root (unsigned local runs):
- `~/Library/Application Support/com.pragprod.msofficeresume/...`

## Packaging Contract
- Direct canonical artifact is `.pkg`.
- Direct installer may upgrade an existing Direct install in place.
- Direct installer must not overwrite an installed MAS build at `/Applications/Office Resume.app`; it must fail with uninstall-first instruction.
- Direct installed visible app bundle name/path is `Office Resume.app` under `/Applications`.
- Helper remains a separate app bundle for login-item semantics, but is embedded inside the main app (`Contents/Library/LoginItems/OfficeResumeHelper.app`) rather than installed as a top-level `/Applications` app.

## Restore Invariants
- Restore runs once per launch instance using external restore markers.
- Only missing documents are reopened.
- `nil`/missing canonical paths are never path-restored directly.
- Per-document failures are tolerated; continue remaining restore operations.

## Entitlement Invariants
- 14-day trial, then paid plans (`$5/mo`, `$50/yr`).
- Offline grace: 7 days.
- When inactive:
  - automatic monitoring disabled
  - automatic restore disabled
  - status/history remain readable
- MAS trial/subscription state comes from StoreKit.
- Direct trial/subscription/free-pass state comes from the backend after verified sign-in.
- Direct new-purchase flow uses Worker-hosted pricing plus Stripe Checkout Sessions.
- Direct paid-account management uses Stripe Billing Portal.

## Free-Pass Invariants (Direct)
- Free-pass is backend-authoritative and tied to verified session identity.
- Production client builds must not grant free-pass via local file/env overrides.
- The backend may combine a checked-in hard-coded email list with env-based additions.

## Support Matrix
- Word/Excel/PowerPoint: document-level capture/restore
- Outlook: relaunch-only restore mode
- OneNote: unsupported in v1, and not shown as a dedicated menu row
