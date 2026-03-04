# Shared Contracts

This file defines cross-component interfaces and invariants.

## Locked Global Constraints
- Product: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- Capture strategy: Accessibility-first (`AXObserver`) + lifecycle notifications
- Polling fallback: not used in v1

## Shared Domain Types
- `OfficeApp`: `word`, `excel`, `powerpoint`, `outlook`, `onenote`
- `DocumentSnapshot`: app, displayName, canonicalPath, isSaved, isTempArtifact, capturedAt
- `AppSnapshot`: app, launchInstanceID, capturedAt, documents, windowsMeta, restoreAttemptedForLaunch
- `LifecycleEvent`: app, type, timestamp, details
- `EntitlementState`: isActive, plan, validUntil, trialEndsAt, lastValidatedAt

## XPC Contract (Menu <-> Helper)
- `getStatus()`
- `setPaused(Bool)`
- `restoreNow(app?)`
- `clearSnapshot(app?)`

Status payload must include:
- `isPaused`, `helperRunning`
- entitlement state summary
- accessibility trust state
- per-app latest snapshot timestamps
- unsupported apps list

## Storage Contract
Per Office app under channel-dependent root:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `unsaved-index-v1.json`
- `unsaved/`

Direct root:
- `~/Library/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

MAS root:
- App Group mirror path:
  - `<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

## Restore Invariants
- Restore runs once per launch instance (one-shot marker).
- Only missing documents are reopened.
- Per-document failures are tolerated; continue remaining restore operations.

## Entitlement Invariants
- 14-day trial, then paid plans (`$5/mo`, `$50/yr`).
- Offline grace: 7 days.
- When inactive:
  - automatic monitoring disabled
  - automatic restore disabled
  - history/log viewing remains read-only

## Support Matrix
- Word/Excel/PowerPoint: document-level capture/restore
- Outlook: relaunch-only restore mode
- OneNote: unsupported in v1, surfaced in UI
