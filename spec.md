# Office Resume v1 - Technical Specification

## 1. Scope and Platform
- Product: `Office Resume`
- Platform: macOS 14+ (Sonoma or newer), Apple Silicon only
- App topology:
  - `MenuBarApp` (UI + account surface + control plane)
  - `LoginItemHelper` (background capture/restore daemon)
  - `OfficeResumeCore` (shared models, adapters, storage, restore, account/entitlement abstractions)
  - `OfficeResumeBackend` (Cloudflare Worker for Direct auth/billing/entitlements)

v1 support:
- Word/Excel/PowerPoint: document-level restore
- Outlook: lifecycle + window metadata capture; restore = relaunch only
- OneNote: unsupported (no dedicated menu UI row)

## 2. Repository and Target Layout
```
OfficeResume.xcworkspace
  OfficeResumeCore/
  OfficeResumeMAS/
  OfficeResumeDirect/
  OfficeResumeHelper/
  OfficeResumeBackend/
```

Two app schemes/targets remain:
1. `OfficeResumeMAS`
2. `OfficeResumeDirect`

Both use shared `OfficeResumeCore`, `OfficeResumeHelper`, and shared menu/account UI. Non-billing divergence is forbidden unless explicitly re-scoped.

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
    let canonicalPath: String?
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

struct FolderAccessGrant: Codable, Hashable {
    let id: String
    let displayName: String
    let rootPath: String
    let bookmarkData: Data
    let createdAt: Date
    let updatedAt: Date
}

struct EntitlementState: Codable {
    let isActive: Bool
    let plan: Plan
    let validUntil: Date?
    let trialEndsAt: Date?
    let lastValidatedAt: Date?
}

enum BillingActionKind: String, Codable {
    case subscribe, manageSubscription
}

struct BillingAction: Codable, Equatable {
    let kind: BillingActionKind
    let title: String
}

struct AccountState: Codable, Equatable {
    let email: String?
    let entitlement: EntitlementState
    let billingAction: BillingAction?
    let statusMessage: String?
    let canSignIn: Bool
    let canSignOut: Bool
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

protocol AccountProvider {
    func currentAccountState() async -> AccountState
    func refreshAccountState() async throws -> AccountState
    func requestSignInLink(email: String) async throws
    func handleIncomingURL(_ url: URL) async throws -> Bool
    func billingActionURL() async throws -> URL?
    func signOut() async throws
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
- Enforce one-shot restore marker per app launch instance using external marker storage.
- Enforce entitlement gating (`canMonitor`, `canRestore`).
- Run as LSUIElement (headless; no visible window).

### 5.2 MenuBarApp
- Run as dockless LSUIElement menu bar app.
- Use one shared menu UI implementation for MAS and Direct.
- Present standard `MenuBarExtra` menu style with:
  - helper connection feedback
  - autostart status/action
  - Accessibility status/action
  - `Pause Tracking` / `Resume Tracking`
  - `Restore Now`
  - `Advanced > Grant Folder Access…`
  - `Advanced > Clear Snapshot`
  - `Advanced > Open Debug Log in Console`
  - `Account…`
  - `Quit`
- Own the shared account window.
- Receive Direct auth callback URLs and hand them to the Direct account provider.
- Start helper via `SMAppService` and sibling-launch fallback.
- `Quit` must terminate both menu app and helper.
- Own the sandboxed folder-grant UI (`NSOpenPanel`) and persist selected directory bookmarks into shared storage for helper consumption.

### 5.3 Core Storage + Engine
- Snapshot storage, event log persistence, temp artifact indexing.
- Dedupe restore planning and one-shot marker handling.
- Artifact purge for stale temp data.
- Shared status/log/marker storage rooted under app group or debug fallback.

### 5.4 Billing Providers
- `StoreKitEntitlementProvider` + MAS account provider
- `StripeEntitlementProvider` + Direct account provider
- Shared `EntitlementState` model + 7-day offline grace policy
- No production synthetic local trial state

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
- Require Accessibility trust (`AXIsProcessTrustedWithOptions` prompt at startup/remediation).
- Refresh trust status periodically while helper runs to catch runtime permission changes.
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
- Query `workbooks`, `name`, `full name`, `saved`.
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
6. If one-shot marker already exists for that app launch instance, return.
7. Query currently open docs where applicable.
8. Diff snapshot docs against currently open docs.
9. Open only missing docs with non-nil canonical paths.
10. Mark restore attempted for launch key.
11. Emit success/failure events with per-item details.

Failure handling:
- Continue after per-document errors.
- Emit `restoreFailed` diagnostics for failed paths.
- For document paths under already-granted roots, helper-held security-scoped access must be active during the restore operation.

## 9. Unsaved Temp Artifact Handling
### 9.1 Index Model
`unsaved-index-v1.json` contains:
- artifact ID
- origin app
- origin launch instance ID
- original display name
- artifact path
- created/updated timestamps
- last referenced snapshot launch ID

### 9.2 Force-save policy
- Trigger during AX-capture cycle for W/E/P when unsaved docs detected.
- Save into `<stateRoot>/unsaved/<artifact-id>.<ext>`.
- Persist/update index mapping.
- Replace unsaved snapshot entries with artifact-backed paths when save succeeds.

### 9.3 Purge policy
Purge artifact when:
1. Not referenced by latest snapshot, and
2. No pending restore flow requires it.

Purge orphan index entries pointing to missing files.

## 10. Storage Layout
### 10.1 Unified primary root (MAS + Direct signed runs)
`<AppGroupContainer>/Saved Application State/<officeBundleID>.savedState/OfficeResume/`

### 10.2 Shared auxiliary root (same app-group-or-debug-fallback root)
- `ipc/daemon-status-v1.json`
- `ipc/daemon-xpc-endpoint-v1.data`
- `restore/folder-access-v1.json`
- `restore/restore-markers-v1.json`
- `logs/debug-v1.log`
- `entitlements/entitlement-cache-v1.json`

### 10.3 Dev-only fallback root (unsigned local runs)
`~/Library/Application Support/com.pragprod.msofficeresume/...`

## 11. Account and Entitlement Architecture
### 11.1 MAS
- StoreKit 2 is the source of truth for active subscription/trial state.
- Account window can refresh StoreKit-backed state and open Apple subscription management.
- Cached entitlement state supports offline grace.

### 11.2 Direct
- Backend is the source of truth for sign-in, trial, free-pass, and Stripe-backed subscription state.
- `POST /auth/request-link` sends email via Resend.
- `GET /auth/verify?token=...` validates the token server-side, mints session, and redirects to app custom URL scheme.
- App stores session token in Keychain and refreshes entitlement cache.
- Direct checkout requires verified sign-in before purchase is possible.
- Signed-in, non-paid Direct users open a Worker-hosted pricing page from the account window.
- Worker-hosted pricing creates Stripe Checkout Sessions for monthly/yearly plans.
- Existing paid Direct subscribers open Stripe Billing Portal.
- Remaining Direct trial time is converted into Stripe-supported subscription-trial settings during Checkout creation so billing starts after unused trial time.
- Debug-only local shortcut may use a returned debug token when explicit backend dev mode is enabled.

### 11.3 Debug Behavior
- Debug entitlement bypass is compile-time gated and requires explicit runtime opt-in.
- Debug bypass must not exist in Release behavior.
- Debug local builds may use local storage fallback when app-group container is unavailable.

## 12. Helper/Menu Coordination
- Preferred transport: XPC.
- Required fallback: shared status file plus distributed command notifications.
- Shared IPC commands include:
  - pause/resume tracking
  - restore now
  - clear snapshot
  - refresh entitlement cache/state
  - prompt Accessibility permissions
  - helper quit
- Menu treats helper as available when XPC is healthy or shared IPC fallback is healthy.
- Menu refresh model:
  - immediate fetch on startup
  - fetch on menu open
  - fetch after user actions
  - file-watch or notification-driven refresh when shared status changes
  - bounded retry/backoff while establishing helper connectivity
- Menu-owned `Grant Folder Access…` writes security-scoped directory bookmarks into the shared root; helper loads those bookmarks lazily during restore.

## 13. XPC Contract Details
Helper status payload must include:
- pause state
- helper running state
- entitlement summary
- Accessibility trust state
- per-app latest snapshot timestamps
- unsupported apps list

Client behavior:
- XPC timeout is bounded.
- On XPC failure, fall back to shared status file and distributed commands.
- UI actions stay enabled when fallback transport is healthy.

## 14. Build, Packaging, and Release Modes
- `Debug`:
  - unsigned allowed
  - local testing supported
  - debug-only bypasses may be enabled manually
- `ReleaseDirect`:
  - signed/notarized `.pkg`
  - bundle path `/Applications/Office Resume.app`
  - embedded helper at `Contents/Library/LoginItems/OfficeResumeHelper.app`
- `ReleaseMAS`:
  - archive/App Store Connect distribution

Direct `.pkg` rules:
- Preinstall must block overwriting MAS build with uninstall-first guidance.
- Payload must remain non-relocatable so install target stays `/Applications/Office Resume.app`.
- Postinstall must stop stale running processes and relaunch cleanly.

## 15. Permissions and Entitlements
- `NSAppleEventsUsageDescription` in menu/helper targets.
- App Sandbox enabled for MAS, Direct, and helper.
- Application Group: `group.com.pragprod.msofficeresume`.
- Login item registration via `SMAppService`.
- Menu app targets require user-selected read/write entitlement to collect folder grants.
- Menu app targets and helper require app-scope security-scoped bookmark entitlement so persistent folder access survives relaunch.
- Direct target/helper require network client entitlement for backend communication.
- Direct target registers a custom URL scheme for auth callback.
- Keychain sharing/access must support menu app + helper session access in signed builds.

## 16. Test Matrix
1. Launch/quit detection for each Office app updates lifecycle log correctly.
2. Accessibility-triggered capture updates snapshot diff correctly for W/E/P.
3. Auto-restore on relaunch opens only missing docs and avoids duplicates.
4. Startup restore pass covers already-running Office apps after login/reboot.
5. One-shot marker prevents repeated restore attempts in the same launch instance.
6. Untitled force-save creates temp artifact + metadata and supports reopen flow.
7. Untitled artifact purge executes after artifact is no longer needed.
8. Outlook limited mode relaunches app but does not attempt unreliable window/message reconstruction.
9. OneNote remains unsupported and absent from dedicated menu messaging.
10. Accessibility denial/grant/revoke updates status correctly while running.
11. Menu fallback transport works when XPC is temporarily unavailable.
12. Direct request-link production path does not expose raw tokens.
13. Direct debug-only request-link shortcut works only when explicit dev mode is enabled.
14. Direct verified user gets one persistent 14-day trial window.
15. Hard-coded and env-extended free-pass allowlist works only for verified emails.
16. Invalid Stripe signatures are rejected; valid webhooks update entitlements.
17. Direct billing entry endpoint returns a Worker-hosted pricing URL for signed-in non-paid users and Billing Portal URL for signed-in paid users.
18. Direct Checkout Session creation uses verified email identity, selected price ID, and converted remaining trial time.
19. MAS StoreKit refresh logic reports active/inactive state correctly.
20. Debug-only entitlement bypass requires explicit runtime opt-in and is absent in Release behavior.
21. Direct `.pkg` install/upgrade works and blocks MAS conflict.
22. Debug log opens from the unified shared log location.
23. Restoring files from already-granted protected roots does not reprompt on every restore.
24. Docs consistency, UI guardrails, spec-drift guardrails, Xcode builds/tests, backend lint/tests, and static analysis pass.
