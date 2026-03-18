# Helper Daemon Spec (`Sources/OfficeResumeHelper`)

## Scope
Background runtime that monitors Office state and performs restore actions.

## Owned Files
- `HelperRuntime.swift`
- `OfficeResumeHelperApp.swift`

## Responsibilities
1. Observe lifecycle events via `NSWorkspace` launch, terminate, activate, and deactivate notifications.
2. Observe session changes via `NSWorkspace` session notifications.
3. Attach and detach AX observers for supported Office processes.
4. Route lifecycle events, AX events, restore commands, and scheduled capture work through a per-app serialized mailbox so only one app-specific command or event is processed at a time.
5. Trigger snapshot capture on AX-driven reconciliation boundaries.
6. Trigger auto-restore on app launch using the restore engine.
7. Trigger startup reconciliation for running supported apps when the helper starts.
8. Expose helper control and status over XPC with shared IPC fallback.
9. Enforce entitlement and pause gating on capture and restore paths.

## Required Runtime Behavior
- On helper startup:
  - refresh entitlement state
  - reconcile currently running supported Office apps in a bounded serialized order
  - publish helper-running status
- Per supported Office app:
  - maintain one serialized mailbox for lifecycle events, AX events, restore commands, and scheduled capture work
  - process only one mailbox item at a time for that app
  - coalesce redundant AX-driven capture requests into at most one pending capture item per app
  - coalesce rapid activate and deactivate churn so stale focus transitions do not fan out into repeated scripting commands
- On app launch:
  - append lifecycle event
  - attach AX observer when possible
  - attempt restore if eligible
  - perform initial reconciliation once the app is stable and scriptable
- On relevant AX notification:
  - debounce briefly
  - capture state if monitoring is active
  - do not issue overlapping scripting work for the same app
- On app deactivate:
  - do one final debounced capture while the app is still scriptable
- On helper startup and session resign-active:
  - reconcile running supported apps in bounded serialized order
- During sparse safety sweep:
  - run only for the current frontmost supported app
  - run no more often than every `30s`
  - skip if a recent AX-driven capture already succeeded
  - stop immediately when the app deactivates or terminates
- On pause or inactive entitlement:
  - cancel pending capture and sweep tasks
  - stop new captures and auto-restore triggers

## Startup and Permissions
- Keep helper LSUIElement behavior.
- Keep helper fully headless.
- Helper bundle is shipped as an embedded login item under the main app.
- Register and host XPC listener at startup.
- Publish daemon status JSON to shared IPC path.
- Observe distributed notification commands (`pause`, `restore-now`, `clear-snapshot`, `refresh-entitlement`, `quit-helper`, `open-accessibility-settings`) and route them to controller handlers.
- Helper runtime assumes Accessibility is required and surfaces that operationally.
- Helper runtime serializes Apple Events so consent or focus churn cannot create prompt storms.

## Reliability Requirements
- Helper shutdown and restart pathways must not block the menu UI thread.
- Startup retries must be bounded.
- Helper status must be cleared and published correctly on start and shutdown.
- Capture must not rely on polling as the primary event source.
- Rapid focus churn after the first scripting access must be coalesced so a single permission sheet cannot fan out into repeated prompts.
- One busy app must not issue overlapping scripting commands for capture, restore, or lifecycle reconciliation.

## Forbidden Changes
- Do not perform UI logic in the helper.
- Do not bypass restore dedupe or one-shot marker rules.
- Do not capture state when monitoring is explicitly disabled.
- Do not reintroduce MAS-specific behavior assumptions into the active runtime.

## Component Acceptance Checks
- Launch and terminate events appear in the local event log.
- Pause disables capture and restore triggers.
- Inactive entitlement disables capture and restore triggers.
- AX observer lifecycle behaves correctly across Office relaunches and focus changes.
- Sparse safety sweep starts and stops correctly.
- Quit command cleanly terminates the helper.
