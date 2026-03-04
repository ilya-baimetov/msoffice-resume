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
- OneNote: unsupported (UI-visible state)

## 2. Repository and Target Layout (Planned)
```
OfficeResume.xcworkspace
  OfficeResumeCore/
  OfficeResumeMAS/
  OfficeResumeDirect/
  OfficeResumeHelper/
  OfficeResumeBackend/   # Cloudflare Worker project for direct entitlements
```

Two app schemes/targets:
1. `OfficeResumeMAS`
2. `OfficeResumeDirect`

Both use shared `OfficeResumeCore` and `OfficeResumeHelper`.

## 3. Core Domain Types

```swift
enum OfficeApp: String, Codable, CaseIterable {
    case word, excel, powerpoint, outlook, onenote
}

enum PollingInterval: String, Codable {
    case oneSecond, fiveSeconds, fifteenSeconds, oneMinute, none
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
    case appLaunched, appTerminated, statePolled, restoreStarted, restoreSucceeded, restoreFailed
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
    func setPollingInterval(_ value: String, reply: @escaping (Bool) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (RestoreCommandResultDTO) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
    func recentEvents(_ limit: Int, reply: @escaping ([LifecycleEventDTO]) -> Void)
}
```

## 5. Module Responsibilities

### 5.1 OfficeResumeHelper
- Register for `NSWorkspace` app launch/terminate notifications.
- Poll adapters at configured interval.
- Persist latest snapshots and append local events.
- Execute restore on relaunch events.
- Enforce one-shot restore marker per app launch instance.
- Enforce entitlement gating (`canMonitor` and `canRestore`).

### 5.2 MenuBarApp
- Show status, recent events, and unsupported-app messaging.
- Controls:
  - `Restore now`
  - `Pause tracking`
  - `Clear snapshot`
  - Polling interval selector
- Start helper via `SMAppService` (login item).
- Display entitlement state and trial/subscription status.

### 5.3 Core Storage + Engine
- Snapshot storage, event logging, temp artifact indexing.
- Diff engine for dedupe restore.
- Purge engine for stale temp artifacts.

### 5.4 Billing Providers
- `StoreKitEntitlementProvider` (MAS)
- `StripeEntitlementProvider` (Direct)
- Shared `EntitlementState` model and cache policy.

## 6. Event Capture and Polling Model

### 6.1 Lifecycle Capture
- Observe Office app launches/quits via `NSWorkspace`.
- Map bundle IDs:
  - `com.microsoft.Word`
  - `com.microsoft.Excel`
  - `com.microsoft.Powerpoint`
  - `com.microsoft.Outlook`
  - `com.microsoft.onenote.mac`

### 6.2 Polling
- Timer loop based on `PollingInterval`.
- Default: 15 seconds.
- `none` disables polling and keeps launch/quit-only capture.
- On each poll:
  1. Fetch current app state from adapter.
  2. Compare with latest stored snapshot.
  3. Persist if changed.
  4. Emit `statePolled` event.

## 7. Office Adapter Behavior

### 7.1 Word Adapter
- AppleScript queries:
  - `documents`
  - `name`
  - `full name` / `posix full name` (if available)
  - `saved`
- Restore:
  - Open missing document paths only.
- Untitled handling:
  - Force-save untitled docs into app storage `unsaved/`.

### 7.2 Excel Adapter
- Query `workbooks`/`documents`, `name`, `full name`, `saved`.
- Restore only missing workbook paths.
- Force-save untitled workbooks to `unsaved/`.

### 7.3 PowerPoint Adapter
- Query `presentations`, `name`, `full name`, `saved`.
- Restore only missing presentation paths.
- Force-save untitled presentations to `unsaved/`.

### 7.4 Outlook Adapter (Limited)
- Capture lifecycle and window metadata (`name`, `id`, `bounds`, visibility where available).
- Restore action: relaunch Outlook app only.
- No message/item-level restore in v1.

### 7.5 OneNote Adapter
- Return unsupported capability status.
- No fetch/restore logic beyond lifecycle event visibility.

## 8. Restore Engine

Algorithm on Office app launch:
1. Check entitlement (`canRestore` and `canMonitor` as required by policy).
2. Load latest snapshot for app.
3. If no snapshot, return.
4. Compute launch instance key from process start metadata.
5. If restore already attempted for this launch key, return.
6. Query current open docs (where supported).
7. Diff snapshot docs minus currently open docs.
8. Open only missing docs.
9. Mark `restoreAttemptedForLaunch=true` for launch key context.
10. Log per-item success/failure and summary.

Failure handling:
- Continue after per-document errors.
- Emit `restoreFailed` with diagnostic details.

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
- Run during polling for W/E/P when unsaved docs detected.
- Save artifacts into:
  - `<stateRoot>/unsaved/<artifact-id>.<ext>`
- Add/update mapping in index.

### 9.3 Purge policy
Purge artifact when:
1. Not referenced by current latest snapshot, and
2. No pending restore flow requires it.

Also purge orphan index entries pointing to missing files.

## 10. Storage Layout

### 10.1 Direct target root
`~/Library/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

### 10.2 MAS target root
App Group container root mirror:
`<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

### 10.3 Files
- `snapshot-v1.json`: latest app snapshot
- `events-v1.ndjson`: append-only local events (rotation optional in v1)
- `unsaved-index-v1.json`: unsaved artifact map
- `unsaved/`: force-saved temp documents

## 11. Entitlements and Permissions

Required:
- `NSAppleEventsUsageDescription` in both app targets.
- App Group entitlement shared by menu app + helper.
- Login item entitlement/registration via `SMAppService`.

MAS-specific:
- App Sandbox enabled.
- Apple Events targeting/exceptions for Office bundle IDs as needed.
- Document explicit risk: MAS review may reject/limit broad automation cases.

Direct-specific:
- Network access for Stripe/backend calls.
- No sandbox constraints required by MAS policy.

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

Rule:
- If `lastValidatedAt` older than 7 days and cannot refresh, set inactive.
- Inactive => disable monitoring and restore; UI remains readable.

### 12.2 MAS (StoreKit 2)
- Single subscription group:
  - `officeresume.monthly`
  - `officeresume.yearly`
- 14-day introductory trial for both.
- Validate current entitlements on startup + periodic refresh.

### 12.3 Direct (Stripe + Worker)
- Stripe prices:
  - monthly `$5`
  - yearly `$50`
  - each with `trial_period_days=14`
- Auth:
  - Email magic link
- Cloudflare Worker endpoints:
  - `POST /auth/request-link`
  - `POST /auth/verify`
  - `GET /entitlements/current`
  - `POST /webhooks/stripe`
- D1/KV store:
  - users
  - subscriptions
  - devices/sessions
  - entitlement cache records

No cross-channel purchase linking in v1.

## 13. XPC Contract Details

### 13.1 Status DTO
- paused flag
- polling interval
- helper running flag
- entitlement summary
- per-app latest snapshot timestamps
- unsupported apps list (includes OneNote)

### 13.2 Commands
- `restoreNow(app?)`: if nil, restore all supported apps with snapshots.
- `clearSnapshot(app?)`: clear one or all snapshots and related unsaved artifacts not referenced.
- `setPaused(Bool)`: toggles polling and restore triggers.
- `setPollingInterval`: applies immediately and persists.

## 14. Build Flavor Configuration
- Shared compile-time flags:
  - `BILLING_MAS`
  - `BILLING_DIRECT`
- Separate entitlements plist files per app target.
- Separate product IDs/config constants per channel.
- Common UI and helper code path wherever possible.

## 15. Error Handling and Logging
- Local-only structured logs.
- Include:
  - timestamp
  - app
  - operation
  - success/failure
  - error code/message
- Keep recent log list available in menu bar UI.
- No remote logging pipeline in v1.

## 16. Test Matrix

1. Launch/quit capture across all Office apps.
2. Polling interval changes apply immediately.
3. W/E/P saved doc snapshot capture and diff correctness.
4. Relaunch restore dedupe opens only missing docs.
5. One-shot marker blocks repeat restore in same launch instance.
6. Untitled force-save creates artifact + index mapping.
7. Unsaved artifact restore works and purges when stale.
8. Outlook relaunch-only flow executes without message-level restore attempts.
9. OneNote shown unsupported in status/UI.
10. Trial active allows monitor/restore.
11. Trial/subscription inactive disables monitor/restore, preserves read-only history.
12. MAS StoreKit entitlement refresh logic correct.
13. Direct Stripe entitlement fetch/refresh logic correct.
14. Offline grace expiration at > 7 days disables paid features.
15. Pause tracking stops capture and automatic restore triggers.
16. Clear snapshot removes active snapshot state and relevant artifacts.
17. Verify no remote telemetry calls exist in app runtime.

## 17. Acceptance Criteria
- All required FRs in `PRD.md` implemented.
- Support matrix behavior exactly matches v1 scope.
- Both MAS and direct schemes build and run.
- Helper remains stable during long-running polling sessions.
- Test matrix pass (automated + manual scenarios).
