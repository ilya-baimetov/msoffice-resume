# Office Resume for Windows v1: Technical Spec

## Status
This document is exploratory and does not amend the canonical macOS implementation contract.

It defines a proposed Windows v1 architecture for Office Resume focused on Word, Excel, and PowerPoint on Microsoft 365 desktop apps for Windows.

## 1. Scope

### In Scope
- Word saved-document capture and restore
- Excel saved-workbook capture and restore
- PowerPoint saved-presentation capture and restore
- system tray app
- automatic restore on app startup
- duplicate guard
- latest snapshot only
- local logs only

### Out of Scope
- Outlook classic
- new Outlook for Windows
- OneNote
- unsaved-document reconstruction
- exact window position/size restore
- cloud telemetry

## 2. Product Assumptions
- Office Resume for Windows is a separate runtime from the macOS app.
- Windows v1 targets desktop Microsoft 365 Apps, not Office on the web.
- The primary capture path uses native Office application events.
- UI Automation and WinEvents are fallback observability tools only.

## 3. Recommended Technology Choices

### 3.1 Host Technology
Use app-level Office add-ins for Word, Excel, and PowerPoint.

Recommended implementation choice for v1:
- C#
- VSTO app-level add-ins
- .NET Framework 4.8

Reasoning:
- fastest path to reliable Office-native open/close hooks
- Windows-only is acceptable for this product line
- lower event-capture risk than UI Automation-first designs

### 3.2 Desktop Shell
Use a separate Windows tray app:
- WPF, C#, .NET Framework 4.8

Keep the tray app and coordinator on the same runtime family as the add-ins to reduce interop and deployment complexity.

### 3.3 IPC
Use local named pipes with JSON payloads.

Fallback for passive status:
- shared status file under LocalAppData

## 4. Runtime Topology

### Components
1. `OfficeResumeTray.exe`
- notification area icon
- settings, status, pause/resume, restore now, clear snapshot, logs, billing/account entry

2. `OfficeResumeCoordinator.exe`
- per-user background process
- snapshot store owner
- restore engine owner
- trial/entitlement cache owner
- named-pipe server

3. `OfficeResume.WordAddin`
4. `OfficeResume.ExcelAddin`
5. `OfficeResume.PowerPointAddin`
- in-process add-ins loaded by each Office host
- convert native Office events into normalized document lifecycle messages
- request restore plans from the coordinator on host startup

## 5. Event Capture Model

### 5.1 Word
Use:
- `Application.DocumentOpen`
- `Application.DocumentBeforeClose`
- startup enumeration of `Application.Documents`

### 5.2 Excel
Use:
- `Application.WorkbookOpen`
- `Application.WorkbookBeforeClose`
- startup enumeration of `Application.Workbooks`

### 5.3 PowerPoint
Use:
- `Application.PresentationOpen`
- `Application.PresentationClose`
- startup enumeration of `Application.Presentations`

### 5.4 Why This Model
These events are native Office desktop hooks and should be materially more reliable than UI Automation for core capture.

## 6. Restore Model

### 6.1 Trigger
Each add-in asks the coordinator for a restore plan when its Office host starts.

This happens for:
- normal app relaunch
- app reopen after logon
- app reopen after update restart

### 6.2 One-Shot Marker
Coordinator stores one restore marker per:
- Office app
- launch instance

Suggested launch-instance key:
- process ID
- process start time

### 6.3 Duplicate Guard
Before restore, the add-in sends the currently open file set.

Coordinator:
1. loads the latest snapshot
2. normalizes saved paths
3. subtracts already-open paths
4. returns only missing files

### 6.4 Restore Execution
Add-ins reopen files using native Office object model:
- Word: document open through Word automation
- Excel: `Workbooks.Open`
- PowerPoint: `Presentations.Open`

Partial failures must not abort the remaining restore plan.

## 7. Snapshot Schema

### 7.1 Types
```text
enum OfficeApp { word, excel, powerpoint }

struct DocumentSnapshot {
  app: OfficeApp
  displayName: string
  canonicalPath: string
  capturedAt: string
}

struct AppSnapshot {
  app: OfficeApp
  launchInstanceID: string
  capturedAt: string
  documents: DocumentSnapshot[]
}
```

### 7.2 Storage Policy
Latest snapshot only per app.

Files:
- `snapshot-v1.json`
- `events-v1.ndjson`
- `restore-markers-v1.json`
- `status-v1.json`
- `debug-v1.log`

Root:
- `%LOCALAPPDATA%\PragProd\OfficeResume\`

Subfolders:
- `state\word\`
- `state\excel\`
- `state\powerpoint\`
- `ipc\`
- `logs\`

## 8. Path Normalization Rules
Normalize all captured paths before comparison:
- trim whitespace
- canonicalize case-insensitively for Windows file system comparison
- resolve local absolute path where possible
- reject empty or placeholder values

Known v1 limitation:
- OneDrive / SharePoint URLs that do not resolve to stable local file paths may be skipped

## 9. Add-In <-> Coordinator Contract

### Requests
- `hello(hostInfo)`
- `capture-state(app, launchInstanceID, documents[])`
- `request-restore-plan(app, launchInstanceID, currentlyOpenDocuments[])`
- `mark-restore-complete(app, launchInstanceID, restoredPaths[], failedPaths[])`
- `set-paused(bool)`
- `clear-snapshot(app?)`
- `refresh-entitlement`
- `get-status`

### Responses
- `status`
- `restore-plan`
- `ack`
- `error`

## 10. Tray App Behavior

### Menu
- status line
- `Pause Tracking` / `Resume Tracking`
- `Restore Now`
- `Clear Snapshot`
- `Open Log`
- `Account...`
- `Quit`

### Tray Responsibilities
- launch coordinator at sign-in
- keep UI separated from add-in logic
- display read-only recent operational state
- surface entitlement/trial state

## 11. Startup Model
- tray app auto-starts at Windows sign-in
- tray app ensures coordinator is running
- Office add-ins do not depend on the tray app being open, only on the coordinator
- if coordinator is unavailable, add-ins should retry briefly, then continue without crashing Office

## 12. Billing and Entitlements

### Proposed Policy
Reuse the same commercial model as macOS:
- 14-day trial
- $5/month
- $50/year
- offline grace cache
- friends-and-family free-pass allowlist

### Windows v1 Recommendation
Do not couple the first Windows technical milestone to billing completion.

Suggested rollout:
1. internal/dev free-pass only
2. production entitlement integration
3. public pricing enablement

## 13. Installer and Deployment

### Canonical Artifact
- signed MSI

### Install Contents
- tray app
- coordinator
- Word add-in
- Excel add-in
- PowerPoint add-in
- prerequisites if needed

### Registration
Register add-ins using the standard Office add-in registry model.

Support:
- per-machine install for simplicity and predictable support

## 14. Reliability Rules
1. Add-ins must never block Office startup for long.
2. Coordinator outages must degrade gracefully.
3. Restore must run at most once per launch instance.
4. Duplicate reopen is treated as a correctness bug.
5. Local logs must be sufficient to diagnose capture vs restore failures.

## 15. Fallback Signals
Do not use these as the primary source of truth, but keep them available for diagnostics or future gap-filling:
- `SetWinEventHook`
- UI Automation event subscriptions

Reason:
- Microsoft explicitly warns that clients should not assume all UI Automation events are raised.

## 16. Security and Privacy
- local-only state
- no document contents uploaded
- no remote telemetry in v1
- no admin-level desktop access equivalent to macOS Accessibility is required for core capture

## 17. Main Technical Risks
1. VSTO is older technology with a narrower long-term future than web add-ins.
2. Office channel/build differences may affect event timing.
3. Cloud-backed documents may not always produce a stable local path.
4. Multiple windows on the same document may need separate future handling.

## 18. Test Matrix

### Automated
1. Snapshot store round-trip
2. Duplicate guard
3. One-shot markers
4. Restore plan generation
5. Coordinator named-pipe contract
6. Trial/entitlement cache logic

### Integration
1. Word open/close events update snapshot
2. Excel open/close events update snapshot
3. PowerPoint open/close events update snapshot
4. Startup restore opens only missing files
5. Restore marker prevents repeated reopen in same launch

### Manual
1. Quit Word with two files open, relaunch Word, verify restore
2. Quit Excel with two files open, relaunch Excel, verify restore
3. Quit PowerPoint with two files open, relaunch PowerPoint, verify restore
4. Log off with files open, sign in again, verify restore path
5. Update Windows or Office, verify restore after app restart
6. Open one file manually before restore completes, verify no duplicate
7. Pause tracking, verify snapshots stop changing
8. Clear snapshot, verify no restore occurs until new capture

## 19. Recommended v1.1 Follow-Ups
1. Unsaved-document temp-artifact support
2. Better OneDrive / SharePoint path mapping
3. Outlook classic limited mode if demand is real
4. Exact window state restoration

## References
- [Word `Application.DocumentOpen`](https://learn.microsoft.com/en-us/office/vba/api/word.application.documentopen)
- [Word `Application.DocumentBeforeClose`](https://learn.microsoft.com/en-us/office/vba/api/word.application.documentbeforeclose)
- [Excel `Application.WorkbookBeforeClose`](https://learn.microsoft.com/en-us/office/vba/api/excel.application.workbookbeforeclose)
- [Excel `Workbooks.Open`](https://learn.microsoft.com/en-us/office/vba/api/Excel.Workbooks.Open)
- [PowerPoint `Application.PresentationOpen`](https://learn.microsoft.com/en-us/office/vba/api/powerpoint.application.presentationopen)
- [PowerPoint `Application.PresentationClose`](https://learn.microsoft.com/en-us/office/vba/api/powerpoint.application.presentationclose)
- [Office Add-ins platform overview](https://learn.microsoft.com/en-us/office/dev/add-ins/overview/office-add-ins)
- [UI Automation event guidance](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-eventsforclients)
- [SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)
- [Outlook add-in compatibility with existing COM add-ins](https://learn.microsoft.com/en-us/office/dev/add-ins/develop/make-office-add-in-compatible-with-existing-com-add-in)
- [Outlook COM add-in inventory guidance](https://learn.microsoft.com/en-us/microsoft-365-apps/outlook/get-started/state-of-com-add-ins)
