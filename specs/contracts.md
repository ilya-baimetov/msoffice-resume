# Shared Contracts

This file defines cross-component interfaces and invariants.

## Locked Global Constraints
- Product: `Office Resume`
- Bundle prefix: `com.pragprod.msofficeresume`
- Platform: macOS 14+, Apple Silicon only
- Capture strategy: Accessibility-first (`AXObserver`) + lifecycle notifications
- Polling fallback: not used in v1
- Runtime behavior parity across MAS/Direct except billing provider internals

## Shared Domain Types
- `OfficeApp`: `word`, `excel`, `powerpoint`, `outlook`, `onenote`
- `DocumentSnapshot`: app, displayName, canonicalPath, isSaved, isTempArtifact, capturedAt
- `AppSnapshot`: app, launchInstanceID, capturedAt, documents, windowsMeta, restoreAttemptedForLaunch
- `LifecycleEvent`: app, type, timestamp, details
- `EntitlementState`: isActive, plan, validUntil, trialEndsAt, lastValidatedAt

## XPC Contract (Menu <-> Helper)
- Transport:
  - preferred: XPC request/reply for status + commands
  - required fallback: shared IPC status file + distributed command notifications
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
Per Office app under unified root policy:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `unsaved-index-v1.json`
- `unsaved/`

Primary root (MAS + Direct signed runs):
- `<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

Dev-only fallback root (unsigned local runs):
- `~/Library/Application Support/com.pragprod.msofficeresume/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

## Packaging Contract
- Direct canonical artifact is `.pkg`.
- Direct installer may upgrade an existing Direct install in place.
- Direct installer must not overwrite an installed MAS build at `/Applications/OfficeResume.app`; it must fail with uninstall-first instruction.

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
  - status/history remain readable

## Free-Pass Invariants (Direct)
- Free-pass is backend-authoritative and tied to verified session identity.
- Production client builds must not grant free-pass via local file/env overrides.

## Support Matrix
- Word/Excel/PowerPoint: document-level capture/restore
- Outlook: relaunch-only restore mode
- OneNote: unsupported in v1, and not shown as a dedicated menu row
