# Helper Daemon Spec (`Sources/OfficeResumeHelper`)

## Scope
Background runtime that captures Office state and performs restore actions.

## Owned Files
- `HelperRuntime.swift`
- `OfficeResumeHelperApp.swift`

## Responsibilities
1. Observe lifecycle events via `NSWorkspace` launch/terminate notifications.
2. Observe lifecycle events via `NSWorkspace` activate/deactivate notifications.
3. Trigger snapshot capture on lifecycle boundaries, bounded launch/restore warm-up retries, and the bounded frontmost refresh loop.
4. Trigger auto-restore on app launch using restore engine.
5. Trigger startup restore/capture reconciliation only for the current frontmost supported Office app when helper starts.
6. Expose helper control/status over XPC service with shared IPC fallback.
7. Enforce entitlement and pause gating on capture/restore paths.
8. Keep behavior channel-neutral except entitlement/account provider implementation selected by channel.
9. Resolve stored security-scoped folder bookmarks before path-based restore.
10. Reconcile running apps on session resign-active transitions.

## Required Runtime Behavior
- On helper startup:
  - refresh entitlement state
  - if the current frontmost app is supported and running, run startup restore/capture reconciliation for that app only
  - do not probe every running Office app immediately at startup
  - publish helper-running status
- On app launch:
  - append lifecycle event
  - attempt restore if eligible
  - if launch restore already touched the app scripting layer, do not immediately issue a second launch capture
  - capture state if monitoring is active and launch restore did not already do the initial scripting pass
  - run a short bounded warm-up capture window while the app remains running only when the app is not frontmost
  - start frontmost refresh loop if the launched app is frontmost
- On app activate:
  - capture state if monitoring is active unless a recent scripting interaction already occurred for that app
  - start frontmost refresh loop for that app
- After restore:
  - run a short bounded warm-up capture window while the app remains running only when the restored app is not frontmost
- On app deactivate:
  - stop any matching frontmost refresh loop immediately
  - suppress rapid deactivate recapture caused by consent/focus churn immediately after a scripting interaction
  - do one final debounced capture while the app is still scriptable
- During frontmost refresh:
  - skip if paused or entitlement cannot monitor
  - run every `1s` on power adapter
  - run every `10s` on battery
  - persist only on state changes
- During launch/restore warm-up:
  - retry capture on a short bounded cadence while the app remains running
  - tolerate transient activate/deactivate focus bounces during Office relaunch
  - stop when the app terminates, the bounded retry window expires, or monitoring becomes inactive
- On pause/inactive entitlement:
  - cancel pending capture/refresh tasks
  - stop new captures and auto-restore triggers

## Startup + Permissions
- Keep helper LSUIElement behavior.
- Keep helper fully headless (no visible helper UI windows).
- Helper bundle is shipped as embedded login item under the main app (`Contents/Library/LoginItems/OfficeResumeHelper.app`), not as a top-level `/Applications` app.
- Register and host XPC listener at startup.
- Publish daemon status JSON to shared IPC path.
- Observe distributed notification commands (`pause`, `restore-now`, `clear-snapshot`, `refresh-entitlement`, `quit-helper`) and route to controller handlers.
- Before restoring document paths from protected locations, resolve matching folder bookmarks from shared storage and hold security-scoped access for the duration of the restore operation.
- Helper sandbox entitlements must include Apple Events authorization for the supported Microsoft Office bundle IDs because the helper is the process that performs Office scripting.

## Reliability Requirements
- Helper shutdown/restart pathways must not block the menu UI thread.
- Startup retries must be bounded.
- Helper status must be cleared/published correctly on start and shutdown.
- Missing or stale folder-access bookmarks must degrade into logged partial failures rather than helper crashes.
- Capture must not depend on Accessibility/TCC state.
- Rapid activate/deactivate focus churn after the first scripting access must be coalesced so a single permission sheet cannot fan out into repeated prompts.

## Forbidden Changes
- Do not perform UI logic in helper.
- Do not bypass restore dedupe or one-shot marker rules.
- Do not capture state when monitoring is explicitly disabled.
- Do not introduce MAS/Direct non-billing behavior drift.

## Component Acceptance Checks
- Launch/terminate events appear in recent event log.
- Pause disables capture and restore triggers.
- Inactive entitlement disables capture and restore triggers.
- Launch/activate/deactivate handling behaves correctly across Office relaunches and focus changes.
- Frontmost refresh loop starts and stops correctly as Office apps gain and lose focus.
- Restoring documents from previously granted protected roots does not trigger repeated sandbox prompts.
- Quit command cleanly terminates the helper.
