# Office Resume v1 - Technical Specification

## 1. Scope and Platform
- Product: `Office Resume`
- Platform: macOS 14+ (Sonoma or newer), Apple Silicon only
- App topology:
  - `MenuBarApp` (UI + control plane)
  - `LoginItemHelper` (background capture/restore daemon)
  - `OfficeResumeCore` (shared models, adapters, storage, restore, entitlement abstractions)

v1 support:
- Word/Excel/PowerPoint: document-level restore
- Outlook: lifecycle + window metadata capture; restore = relaunch only
- OneNote: unsupported (no dedicated menu UI row)

## 2. Repository and Target Layout (Planned)
```
OfficeResume.xcworkspace
  OfficeResumeCore/
  OfficeResumeMAS/
  OfficeResumeDirect/
  OfficeResumeHelper/
  OfficeResumeBackend/   # Cloudflare Worker project for direct entitlements
```

Two app schemes/targets remain:
1. `OfficeResumeMAS`
2. `OfficeResumeDirect`

Both use shared `OfficeResumeCore`, `OfficeResumeHelper`, and shared menu UI. Non-billing divergence is forbidden unless explicitly re-scoped.

## 2.1 Componentized Spec Set
Use this file as the system-level contract, then apply component specs for scoped implementation:

- `specs/contracts.md` - cross-component interfaces and invariants
- `specs/core.md` - core module scope (`Sources/OfficeResumeCore/**`, `Tests/OfficeResumeCoreTests/**`)
- `specs/helper-daemon.md` - helper runtime scope (`Sources/OfficeResumeHelper/**`)
- `specs/menu-ui.md` - menu UI scope (`Sources/OfficeResumeDirect/**`, `Sources/OfficeResumeMAS/**`, `Sources/MenuUIShared/**`)
- `specs/backend-worker.md` - direct entitlement backend scope (`OfficeResumeBackend/**`)

When conflicts exist:
1. `spec.md` wins over component specs.
2. `specs/contracts.md` wins over component-local details.

## 3. Core Domain Types

```swift
enum OfficeApp: String, Codable, CaseIterable {
    case word, excel, powerpoint, outlook, onenote
}

struct DocumentSnapshot: Codable, Hashable {
    let app: OfficeApp
    let displayName: String
    let canonicalPath: String
    let isSaved: Bool
    let isTempArtifact: Bool
    let capturedAt: Date
}

struct WindowMetadata: Codable, Hashable {
    let id: String?
    let title: String?
    let bounds: String?
    let rawClass: String?
}

struct AppSnapshot: Codable {
    let app: OfficeApp
    let launchInstanceID: String
    let capturedAt: Date
    let documents: [DocumentSnapshot]
    let windowsMeta: [WindowMetadata]
    var restoreAttemptedForLaunch: Bool
}

enum LifecycleEventType: String, Codable {
    case appLaunched, appTerminated, stateCaptured, restoreStarted, restoreSucceeded, restoreFailed
}

struct LifecycleEvent: Codable {
    let app: OfficeApp
    let type: LifecycleEventType
    let timestamp: Date
    let details: [String: String]
}
```

## 4. Public Protocols

```swift
protocol OfficeAdapter {
    var app: OfficeApp { get }
    func fetchState() async throws -> AppSnapshot
    func restore(snapshot: AppSnapshot) async throws -> RestoreResult
    func forceSaveUntitled(state: AppSnapshot) async throws -> [DocumentSnapshot]
}

protocol EntitlementProvider {
    func currentState() async -> EntitlementState
    func refresh() async throws -> EntitlementState
    func canRestore() async -> Bool
    func canMonitor() async -> Bool
}
```

XPC-facing API (helper service):

```swift
@objc protocol DaemonXPC {
    func getStatus(_ reply: @escaping (DaemonStatusDTO) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (RestoreCommandResultDTO) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
}
```

## 5. Module Responsibilities

### 5.1 OfficeResumeHelper
- Observe lifecycle events via `NSWorkspace` launch/terminate notifications.
- Register `AXObserver` per running Office process.
- Capture state on Accessibility events as primary trigger.
- Persist latest snapshots and append local events.
- Execute restore on relaunch events.
- Execute startup restore pass for already-running Office apps.
- Enforce one-shot restore marker per app launch instance.
- Enforce entitlement gating (`canMonitor`, `canRestore`).
- Run as LSUIElement (headless; no visible window).

### 5.2 MenuBarApp
- Run as dockless LSUIElement menu bar app.
- Use one shared menu UI implementation for MAS and Direct.
- Present standard `MenuBarExtra` menu style with:
  - `Pause Tracking` / `Resume Tracking`
  - `Restore Now`
  - `Advanced > Clear Snapshot`
  - `Advanced > Open Debug Log in Console`
  - `Quit`
- Show accessibility status:
  - `Accessibility: OK`
  - `Accessibility: click to fix` (opens system settings)
- Show autostart status:
  - `Autostart: OK`
  - `Autostart: click to fix` (opens Login Items settings)
- Start helper via `SMAppService` and sibling-launch fallback.
- `Quit` must terminate both menu app and helper.

### 5.3 Core Storage + Engine
- Snapshot storage, event log persistence, temp artifact indexing.
- Dedupe restore planning and one-shot marker handling.
- Artifact purge for stale temp data.

### 5.4 Billing Providers
- `StoreKitEntitlementProvider` (MAS)
- `StripeEntitlementProvider` (Direct)
- Shared `EntitlementState` model + 7-day offline grace policy.

## 6. Event Capture Model

### 6.1 Lifecycle Capture
- Observe Office app launches/quits via `NSWorkspace`.
- Bundle ID map:
  - `com.microsoft.Word`
  - `com.microsoft.Excel`
  - `com.microsoft.Powerpoint`
  - `com.microsoft.Outlook`
  - `com.microsoft.onenote.mac`

### 6.2 Accessibility Capture (Primary)
- Require accessibility trust (`AXIsProcessTrustedWithOptions` prompt at startup).
- Refresh trust status periodically while helper runs (~2s cadence).
- On app launch, attach `AXObserver` and subscribe to:
  - `kAXWindowCreatedNotification`
  - `kAXUIElementDestroyedNotification`
  - `kAXFocusedWindowChangedNotification`
  - `kAXTitleChangedNotification`
- Debounce per app (target 500-800ms).
- On debounce fire:
  1. Fetch current app state from adapter.
  2. Compare with latest stored snapshot.
  3. Persist on change.
  4. Emit `stateCaptured` event source `ax`.

## 7. Office Adapter Behavior

### 7.1 Word Adapter
- AppleScript queries: `documents`, `name`, `full name`/`posix full name`, `saved`.
- Restore: open missing paths only.
- Untitled handling: force-save to `unsaved/`.

### 7.2 Excel Adapter
- Query `workbooks`/`documents`, `name`, `full name`, `saved`.
- Restore missing workbook paths only.
- Force-save untitled workbooks to `unsaved/`.

### 7.3 PowerPoint Adapter
- Query `presentations`, `name`, `full name`, `saved`.
- Restore missing presentation paths only.
- Force-save untitled presentations to `unsaved/`.

### 7.4 Outlook Adapter (Limited)
- Capture lifecycle and window metadata.
- Restore action: activate/relaunch Outlook only.
- No message/item-level reconstruction in v1.

### 7.5 OneNote Adapter
- Unsupported capability status only.
- No fetch/restore beyond lifecycle visibility.

## 8. Restore Engine

On Office app launch (and helper startup pass for already-running apps):
1. Refresh entitlement.
2. If paused or cannot restore, return.
3. Load latest snapshot for app.
4. If none, return.
5. Build launch instance key.
6. If one-shot marker already set, return.
7. Query currently open docs where applicable.
8. Diff snapshot docs against currently open docs.
9. Open only missing docs.
10. Mark restore attempted for launch key.
11. Emit success/failure events with per-item details.

Failure handling:
- Continue after per-document errors.
- Emit `restoreFailed` diagnostics for failed paths.

## 9. Unsaved Temp Artifact Handling

### 9.1 Index Model
`unsaved-index-v1.json` contains:
- artifact ID
- origin app
- origin launch instance ID
- original display name
- artifact path
- created/updated timestamps
- last referenced snapshot ID

### 9.2 Force-save policy
- Trigger during AX-capture cycle for W/E/P when unsaved docs detected.
- Save into `<stateRoot>/unsaved/<artifact-id>.<ext>`.
- Persist/update index mapping.

### 9.3 Purge policy
Purge artifact when:
1. Not referenced by latest snapshot, and
2. No pending restore flow requires it.

Purge orphan index entries pointing to missing files.

## 10. Storage Layout

### 10.1 Unified primary root (MAS + Direct)
`<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

### 10.2 Dev-only fallback root (unsigned local runs)
`~/Library/Application Support/com.pragprod.msofficeresume/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

### 10.3 Files
- `snapshot-v1.json`: latest snapshot
- `events-v1.ndjson`: append-only local events
- `unsaved-index-v1.json`: unsaved artifact index
- `unsaved/`: force-saved temp documents

## 11. Entitlements and Permissions

Required:
- `NSAppleEventsUsageDescription` in app/helper targets.
- Accessibility permission/trust for full capture fidelity.
- App Group entitlement shared by menu app + helper.
- Login item registration via `SMAppService`.
- `LSUIElement=YES` for menu app and helper targets.

MAS-specific:
- App Sandbox enabled for menu app and helper.
- Apple Events targeting/exceptions for Office bundle IDs as required.
- Document App Review risk for automation permissions.

Direct-specific:
- App Sandbox enabled for menu app and helper.
- Network access for Stripe/backend calls.
- Release path assumes signed entitlement-capable app-group runtime.

## 12. Billing and Entitlement Architecture

## 12.1 Entitlement state
```swift
struct EntitlementState: Codable {
    enum Plan: String, Codable { case trial, monthly, yearly, none }
    let isActive: Bool
    let plan: Plan
    let validUntil: Date?
    let trialEndsAt: Date?
    let lastValidatedAt: Date?
}
```

Rules:
- Offline grace: if refresh fails and last validation <= 7 days, remain active.
- Inactive entitlement disables capture and restore; status/history remain readable.

### 12.2 MAS (StoreKit 2)
- Subscription group:
  - `officeresume.monthly`
  - `officeresume.yearly`
- 14-day introductory trial.
- Validate current entitlements at startup and periodic refresh.

### 12.3 Direct (Stripe + Worker)
- Stripe prices:
  - monthly `$5`
  - yearly `$50`
  - `trial_period_days=14`
- Auth: email magic link.
- Worker endpoints:
  - `POST /auth/request-link`
  - `POST /auth/verify`
  - `GET /entitlements/current`
  - `POST /webhooks/stripe`
- Free-pass policy (Direct): backend-authoritative allowlist tied to verified session identity.
- Production client path must not grant free-pass via local file/env overrides.

## 13. XPC Contract Details

### 13.0 Transport
- Preferred: XPC request/reply for status + commands.
- Required fallback:
  - helper publishes status JSON to shared IPC path
  - app reads shared status when XPC fetch fails
  - app posts distributed command notifications
  - helper subscribes and routes to same handlers

Shared IPC fallback path rules:
- primary: app-group container `ipc/`
- dev-only unsigned fallback: `~/Library/Application Support/com.pragprod.msofficeresume/ipc/`

### 13.1 Status DTO
Must include:
- pause flag
- helper running flag
- entitlement summary
- accessibility trust state
- per-app latest snapshot timestamps
- unsupported apps list

### 13.2 Commands
- `restoreNow(app?)`
- `clearSnapshot(app?)`
- `setPaused(Bool)`

## 14. Build Flavor Configuration
- Compile flags:
  - `BILLING_MAS`
  - `BILLING_DIRECT`
- Separate entitlements plist per target where required.
- Separate bundle IDs per distribution channel.
- Common UI/helper/core behavior across channels.
- Runtime app process/display naming unified as `OfficeResume`.
- Direct `.pkg` preinstall policy: if `/Applications/Office Resume.app` exists with MAS bundle ID, abort install and require uninstall-first flow.
- Direct `.pkg` must be built with non-relocatable bundle components so install target remains `/Applications/Office Resume.app`.
- Helper packaging policy: helper app bundle is embedded at `Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app` and is not installed as `/Applications/OfficeResumeHelper.app`.

## 15. Error Handling and Logging
- Local-only structured logs.
- Include timestamp, app, operation, result, and error context.
- Menu action opens local debug log in Console.
- No remote logging pipeline in v1.

## 16. Test Matrix

1. Launch/quit capture across all Office apps.
2. Accessibility-trusted path attaches AX observers and captures transitions.
3. Accessibility-denied path degrades gracefully and surfaces clear status.
4. W/E/P saved doc snapshot capture and diff correctness.
5. Relaunch restore dedupe opens only missing docs.
6. Startup restore pass handles already-running Office apps after login/reboot.
7. One-shot marker blocks repeat restore in same launch instance.
8. Untitled force-save creates artifact + index mapping.
9. Unsaved artifact restore works and stale purge executes.
10. Outlook relaunch-only flow executes without message-level restore.
11. OneNote remains unsupported.
12. Trial active allows monitor/restore.
13. Inactive entitlement disables monitor/restore while keeping read-only status/history.
14. MAS StoreKit refresh logic correct.
15. Direct Stripe entitlement refresh logic correct.
16. Offline grace expiration > 7 days disables paid features.
17. Pause tracking stops capture and auto-restore triggers.
18. Clear snapshot removes active restore state and relevant artifacts.
19. No remote telemetry calls emitted.
20. Direct free-pass only granted when backend allowlist/session says active.
21. Direct `.pkg` install/upgrade works for repeat Direct installs.
22. Direct `.pkg` preinstall check blocks install when MAS build is already installed at `/Applications/Office Resume.app`.
23. Installed helper is not visible as a top-level `/Applications` app.
24. Menu autostart status reflects main app + helper login-item health and can open Login Items settings.

## 17. Acceptance Criteria
- All PRD required behaviors implemented.
- Support matrix behavior matches v1 scope exactly.
- Both MAS and Direct schemes build and run.
- Helper is stable during long-running AX sessions.
- Test matrix passes (automated + manual scenarios).
- Docs/spec updates remain aligned with implementation.
