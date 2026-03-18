# Office Resume v1 - Technical Specification

## 1. Scope and Platform
- Product: `Office Resume`
- Platform: macOS 14+ (Sonoma or newer), Apple Silicon only
- Shipping channel: Direct only
- App topology:
  - `MenuBarApp` (UI, account surface, control plane)
  - `LoginItemHelper` (background capture/restore daemon)
  - `OfficeResumeCore` (shared models, adapters, storage, restore, account, entitlement abstractions)
  - `office-resume` Cloudflare Worker (static site assets plus mounted Direct backend/API)
  - `OfficeResumeBackend` (backend module mounted inside the unified Worker for Direct auth, billing, entitlements)

v1 support:
- Word, Excel, PowerPoint: document-level restore
- Outlook: lifecycle plus limited window metadata capture; restore = relaunch only
- OneNote: unsupported

## 2. Repository and Target Layout
```text
OfficeResume.xcworkspace
  OfficeResumeCore/
  OfficeResumeDirect/
  OfficeResumeHelper/
  OfficeResumeBackend/
  OfficeResumeMAS/        # legacy, deprecated, not part of v1 shipping contract
```

Canonical shipping target and scheme:
1. `OfficeResumeDirect`

Legacy note:
- `OfficeResumeMAS` may remain temporarily in the repository during migration.
- It is not part of the active release contract, acceptance gate, or future architecture decisions.

## 3. Componentized Spec Set
Use this file as the system-level contract, then apply component specs for scoped implementation:
- `specs/contracts.md`
- `specs/core.md`
- `specs/helper-daemon.md`
- `specs/menu-ui.md`
- `specs/backend-worker.md`

When conflicts exist:
1. `spec.md` wins over component specs.
2. `specs/contracts.md` wins over component-local details.

## 4. Core Domain Types
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
    let rawRole: String?
    let isVisible: Bool?
    let isMinimized: Bool?
}

struct AppSnapshot: Codable {
    let app: OfficeApp
    let launchInstanceID: String
    let capturedAt: Date
    let documents: [DocumentSnapshot]
    let windowsMeta: [WindowMetadata]
}

enum LifecycleEventType: String, Codable {
    case appLaunched
    case appActivated
    case appDeactivated
    case appTerminated
    case stateCaptured
    case restoreStarted
    case restoreSucceeded
    case restoreFailed
}

struct LifecycleEvent: Codable {
    let app: OfficeApp
    let type: LifecycleEventType
    let timestamp: Date
    let details: [String: String]
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

## 5. Public Protocols
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

XPC-facing API:
```swift
@objc protocol DaemonXPC {
    func getStatus(_ reply: @escaping (DaemonStatusDTO) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (RestoreCommandResultDTO) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
    func openAccessibilitySettings(_ reply: @escaping (Bool) -> Void)
}
```

## 6. Module Responsibilities
### 6.1 OfficeResumeHelper
- Observe launch, terminate, activate, deactivate, and session transitions via `NSWorkspace`.
- Discover supported Office processes and attach or detach AX observers.
- Treat AX notifications as the primary event substrate for capture scheduling.
- Resolve canonical Office state through AppleScript only after meaningful external events or bounded reconciliation triggers.
- Serialize per-app lifecycle events, AX events, restore commands, and scheduled capture work through a per-app mailbox so only one app-specific operation runs at a time.
- Persist latest snapshots and append local events.
- Execute restore on relaunch and helper startup reconciliation.
- Enforce one-shot restore marker per app launch instance.
- Enforce entitlement gating (`canMonitor`, `canRestore`).
- Run as LSUIElement.

### 6.2 MenuBarApp
- Run as a dockless LSUIElement menu bar app.
- Present native `MenuBarExtra` menu style.
- Show helper connection, Accessibility status, autostart status, pause state, restore controls, account entry point, and quit.
- Own the shared account window.
- Receive Direct auth callback URLs and hand them to the Direct account provider.
- Start helper via `SMAppService` and sibling-launch fallback.
- `Quit` terminates both menu app and helper.
- Accessibility remediation is initiated from the menu app but executed by the helper so the helper can request trust for its own process identity.

### 6.3 Core Storage and Engine
- Snapshot storage, event log persistence, temp artifact indexing.
- Dedupe restore planning and one-shot marker handling.
- Artifact purge for stale temp data.
- Shared status, log, marker, and entitlement-cache storage rooted under the direct-only Application Support root.

### 6.4 Billing Provider
- Direct entitlement provider and Direct account provider
- shared `EntitlementState` model plus 7-day offline grace
- no production synthetic local trial state

## 7. Event Capture Model
### 7.1 Primary Capture Substrate: AX
The primary observation model is Accessibility, not polling.

Per supported Office process:
- create one `AXObserver` for the process pid
- register for the relevant app/window notifications exposed by that process
- use AX notifications to detect meaningful external changes and schedule a scripted reconciliation pass

Rules:
- AX events do not directly mutate snapshots.
- AX events schedule a debounced app-state fetch through the per-app mailbox.
- If one fetch or restore is already in flight for that app, later AX events must coalesce rather than start overlapping work.

### 7.2 Secondary Lifecycle Substrate: NSWorkspace
`NSWorkspace` remains required, but only for coarse lifecycle and session boundaries:
- `didLaunchApplication`
- `didTerminateApplication`
- `didActivateApplication`
- `didDeactivateApplication`
- `sessionDidResignActive`
- `sessionDidBecomeActive` when useful

Use cases:
- discover a newly launched Office app and attach AX
- clear helper state when an Office process terminates
- trigger one final debounced capture on app deactivate while the process is still alive
- reconcile running apps on helper start and session transitions

Do not treat `didTerminateApplication` as a valid final snapshot point.

### 7.3 Tertiary State Resolution: Office Scripting
Office AppleScript and Apple Events are used only to:
- fetch canonical Office state after meaningful AX or lifecycle triggers
- execute restore operations
- force-save untitled recoverable docs

Rules:
- only one Apple Events interaction per app may be in flight at a time
- repeated focus churn must not amplify into repeated Apple Events submissions
- release builds use stable signed identities so TCC grants persist predictably

### 7.4 Capture Triggers
The helper may schedule a scripted reconciliation on:
1. app launch stabilization
2. meaningful AX app or window notifications
3. app deactivate after debounce
4. helper startup reconciliation for running supported apps
5. session resign-active handling
6. post-restore warm-up reconciliation
7. sparse frontmost safety sweep only when no recent AX-driven reconciliation has occurred

### 7.5 Sparse Safety Sweep
A sparse safety sweep is permitted only as a backstop.

Rules:
- run only for the current frontmost supported Office app
- run no more often than every `30s`
- skip if an AX-driven reconciliation succeeded recently
- stop immediately on app deactivate or terminate

This sweep exists to reduce edge-case misses if Office fails to emit a useful AX notification. It is not the primary capture mechanism.

### 7.6 Capture Cycle
On each scheduled capture cycle:
1. Resolve current Office state from the adapter.
2. Compare with latest stored snapshot.
3. Persist only on change.
4. Emit `stateCaptured` event with source details.
5. Update launch-instance bookkeeping if needed.

## 8. Office Adapter Behavior
### 8.1 Word Adapter
- Query `documents`, `name`, `full name` or `posix full name`, `saved`.
- Restore: open missing paths only.
- Untitled handling: force-save to `unsaved/`.
- AX decides when reconciliation should occur; Word scripting resolves the canonical document list.

### 8.2 Excel Adapter
- Query `workbooks`, `name`, `full name`, `saved`.
- Restore missing workbook paths only.
- Force-save untitled workbooks to `unsaved/`.
- AX decides when reconciliation should occur; Excel scripting resolves the canonical workbook list.

### 8.3 PowerPoint Adapter
- Query `presentations`, `name`, `full name`, `saved`, and document-window metadata where useful.
- Restore missing presentation paths only.
- Force-save untitled presentations to `unsaved/`.
- AX decides when reconciliation should occur; PowerPoint scripting resolves the canonical presentation list.

### 8.4 Outlook Adapter
- Capture lifecycle and limited window metadata.
- Restore action: activate or relaunch Outlook only.
- No message or item-level reconstruction in v1.

### 8.5 OneNote Adapter
- Unsupported capability status only.
- No fetch or restore beyond lifecycle visibility.

## 9. Restore Engine
On Office app launch and helper startup reconciliation:
1. Refresh entitlement.
2. If paused or cannot restore, return.
3. Load latest snapshot for app.
4. If none, return.
5. Build launch-instance key.
6. If one-shot marker already exists for that app launch instance, return.
7. Query currently open docs where applicable.
8. Diff snapshot docs against currently open docs.
9. Open only missing docs with non-`nil` canonical paths.
10. Mark restore attempted for launch key.
11. Emit success or failure events with per-item details.

Failure handling:
- continue after per-document errors
- emit `restoreFailed` diagnostics for failed paths
- use `NSWorkspace.open` or Launch Services first when appropriate, with Office scripting fallback only if needed

## 10. Unsaved Temp Artifact Handling
### 10.1 Index Model
`unsaved-index-v1.json` contains:
- artifact ID
- origin app
- origin launch instance ID
- original display name
- artifact path
- created and updated timestamps
- last referenced snapshot launch ID

### 10.2 Force-save Policy
- Trigger during capture cycle for Word, Excel, and PowerPoint when unsaved docs are detected.
- Save into `<root>/state/<officeBundleID>/unsaved/<artifact-id>.<ext>`.
- Persist or update index mapping.
- Replace unsaved snapshot entries with artifact-backed paths when save succeeds.

### 10.3 Purge Policy
Purge an artifact when:
1. it is not referenced by the latest snapshot, and
2. no pending restore flow requires it.

Purge orphan index entries that point to missing files.

## 11. Storage Layout
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
- keep only the most recent 24 hours of local debug log history

The direct-only architecture does not depend on sandbox container indirection.

## 12. Account and Entitlement Architecture
### 12.1 Direct
- Backend is the source of truth for sign-in, trial, free-pass, and Stripe-backed subscription state.
- The canonical Worker name is `office-resume`; it serves the site at `/` and the backend at `/api/*`.
- `POST /api/auth/request-link` sends email via Resend.
- `GET /api/auth/verify?token=...` validates the token server-side, mints session, and redirects to the app custom URL scheme.
- App stores the session token in Keychain and refreshes entitlement cache.
- Direct checkout requires verified sign-in before purchase is possible.
- Signed-in non-paid users open a Worker-hosted pricing page from the account window.
- Worker-hosted pricing creates Stripe Checkout Sessions for monthly and yearly plans.
- Existing paid subscribers open Stripe Billing Portal.
- Remaining Direct trial time is converted into Stripe-supported subscription-trial settings during Checkout creation so billing starts after unused trial time.
- The checked-in free-pass allowlist lives in `OfficeResumeBackend/src/free-pass-emails.js`; environment allowlist values may extend it backend-side.

## 13. Helper/Menu Coordination
- Preferred transport: XPC.
- Required fallback: shared status file plus distributed command notifications.
- Shared IPC commands include:
  - pause or resume tracking
  - restore now
  - clear snapshot
  - refresh entitlement
  - quit helper
  - open accessibility settings

Status includes:
- `helperRunning`
- `isPaused`
- `accessibilityTrusted`
- entitlement summary
- per-app latest snapshot timestamps
- unsupported apps list

## 14. Permissions and Packaging
### 14.1 Accessibility
- Accessibility permission is mandatory for monitoring.
- Menu app surfaces clear status and remediation.
- Helper logic must not create repeated Accessibility prompt loops.

### 14.2 Apple Events
- Apple Events or Automation permission is required for Office scripting.
- Permission is requested lazily on first real interaction with each Office app.
- Helper logic must serialize Office scripting so focus churn cannot create repeated prompt storms.

### 14.3 Direct Packaging
- Release artifact is a Developer ID signed and notarized `.pkg`.
- Preinstall may block legacy MAS conflicts if they still exist on disk.
- Helper remains an embedded login item under the main app.
- Stable signed identity is mandatory for predictable TCC behavior in release builds.

## 15. Migration Constraints
The current codebase still contains legacy MAS, sandbox, and no-AX assumptions.

Migration must:
1. update docs first
2. land the AX event substrate before deleting the old polling-first helper paths
3. keep billing and backend behavior intact while capture architecture changes
4. remove or quarantine legacy MAS-only assumptions from acceptance gates and review rules

See `docs/direct-only-ax-migration-plan.md` for the staged rollout.

## 16. XPC Contract Details
Required helper commands:
- status fetch
- pause or resume
- restore now
- clear snapshot
- accessibility remediation

Required menu reactions:
- helper disconnected
- helper connected
- accessibility missing
- accessibility granted
- autostart unhealthy
- autostart healthy
- entitlement changed

## 17. Test Matrix
1. AX observer attaches and detaches correctly across launch and terminate.
2. AX-driven capture updates snapshot diff correctly for Word, Excel, and PowerPoint.
3. Auto-restore on relaunch opens only missing docs and avoids duplicates.
4. Startup reconciliation handles multiple running supported apps after login or reboot.
5. One-shot marker prevents repeated restore attempts in the same launch instance.
6. Untitled force-save artifacts are reopened and purged correctly.
7. Sparse safety sweep does not create prompt storms and does not overlap active scripting work.
8. Outlook limited mode relaunches the app but does not attempt unreliable item reconstruction.
9. OneNote remains unsupported.
10. Direct auth flow stores the session in Keychain and refreshes entitlements.
11. Free-pass remains backend-authoritative only.
12. Direct billing entry endpoint returns a Worker-hosted pricing URL for signed-in non-paid users and a Billing Portal URL for paid users.
13. Direct Checkout Session creation uses verified email identity, selected price ID, and converted remaining trial time.
14. Direct `.pkg` install and upgrade works.
15. Accessibility flow works and does not reprompt repeatedly once granted to the signed build.
16. Apple Events prompts do not loop endlessly under focus churn.
17. No remote analytics endpoints are invoked.
