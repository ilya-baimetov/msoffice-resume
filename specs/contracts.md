# Shared Contracts

This file defines cross-component interfaces and invariants for the direct-only product.

## Locked Global Constraints
- Product: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- Shipping channel: Direct only
- Capture strategy:
  - primary: AX notifications
  - secondary: `NSWorkspace` lifecycle and session notifications
  - tertiary: Office scripting for canonical state resolution and restore
- Sparse safety reconciliation may exist, but only as a backup to AX.

## Shared Domain Types
- `OfficeApp`: `word`, `excel`, `powerpoint`, `outlook`, `onenote`
- `DocumentSnapshot`: `app`, `displayName`, `canonicalPath?`, `isSaved`, `isTempArtifact`, `capturedAt`
- `WindowMetadata`: `id`, `title`, `bounds`, `rawRole`, `isVisible`, `isMinimized`
- `AppSnapshot`: `app`, `launchInstanceID`, `capturedAt`, `documents`, `windowsMeta`
- `LifecycleEvent`: `app`, `type`, `timestamp`, `details`
- `EntitlementState`: `isActive`, `plan`, `validUntil`, `trialEndsAt`, `lastValidatedAt`
- `BillingAction`: `kind` (`subscribe` or `manageSubscription`) plus user-facing title
- `AccountState`: signed-in email or `nil`, current entitlement snapshot, optional billing action, sign-in and sign-out availability flags, optional status message

## XPC Contract (Menu <-> Helper)
Transport:
- preferred: XPC request/reply for status and commands
- required fallback: shared IPC status file plus distributed command notifications

Required commands:
- `getStatus()`
- `setPaused(Bool)`
- `restoreNow(app?)`
- `clearSnapshot(app?)`
- `openAccessibilitySettings()`

Required shared IPC fallback commands:
- `pause`
- `restore-now`
- `clear-snapshot`
- `refresh-entitlement`
- `quit-helper`
- `open-accessibility-settings`

Status payload includes:
- `isPaused`
- `helperRunning`
- `accessibilityTrusted`
- entitlement state summary
- per-app latest snapshot timestamps
- unsupported apps list

## Storage Contract
Root:
- `~/Library/Application Support/com.pragprod.msofficeresume/`

Per Office app:
- `state/<officeBundleID>/snapshot-v1.json`
- `state/<officeBundleID>/events-v1.ndjson`
- `state/<officeBundleID>/unsaved-index-v1.json`
- `state/<officeBundleID>/unsaved/`

Shared auxiliary files:
- `ipc/daemon-status-v1.json`
- `ipc/daemon-xpc-endpoint-v1.data`
- `restore/restore-markers-v1.json`
- `logs/debug-v1.log`
- `entitlements/entitlement-cache-v1.json`

Log retention:
- keep only the most recent 24 hours of `logs/debug-v1.log`

## Packaging Contract
- Direct canonical artifact is `.pkg`.
- Direct installer may upgrade an existing Direct install in place.
- Installed visible app bundle name and path is `Office Resume.app` under `/Applications`.
- Helper remains a separate app bundle for login-item semantics, but is embedded inside the main app at `Contents/Library/LoginItems/OfficeResumeHelper.app`.

## Restore Invariants
- Restore runs once per launch instance using external restore markers.
- Only missing documents are reopened.
- `nil` canonical paths are never path-restored directly.
- Per-document failures are tolerated; remaining restore operations continue.
- Outlook restore remains relaunch-only.

## Permission Invariants
- Accessibility is required for monitoring.
- Office scripting uses Apple Events and must be serialized per app.
- Repeated prompt storms after grant are bugs.
- Release builds require stable signed identity for predictable TCC behavior.

## Entitlement Invariants
- 14-day trial, then paid plans (`$5/mo`, `$50/yr`).
- Offline grace: 7 days.
- When inactive:
  - automatic monitoring disabled
  - automatic restore disabled
  - status and history remain readable
- Direct trial, subscription, and free-pass state comes from the backend after verified sign-in.
- Direct new-purchase flow uses Worker-hosted pricing plus Stripe Checkout Sessions.
- Direct paid-account management uses Stripe Billing Portal.

## Free-Pass Invariants
- Free-pass is backend-authoritative and tied to verified session identity.
- Production client builds must not grant free-pass via local file or env overrides.
- The backend may combine the checked-in hard-coded email list in `OfficeResumeBackend/src/free-pass-emails.js` with env-based additions.

## Support Matrix
- Word, Excel, PowerPoint: document-level capture and restore
- Outlook: relaunch-only restore mode
- OneNote: unsupported in v1 and not shown as a dedicated menu row
