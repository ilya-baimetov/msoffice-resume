# Helper Daemon Spec (`Sources/OfficeResumeHelper`)

## Scope
Background runtime that captures Office state and performs restore actions.

## Owned Files
- `HelperRuntime.swift`
- `OfficeResumeHelperApp.swift`

## Responsibilities
1. Observe lifecycle events via `NSWorkspace` launch/terminate notifications.
2. Observe Accessibility events via `AXObserver` for running Office processes.
3. Trigger snapshot capture on AX signals (debounced per app).
4. Trigger auto-restore on app launch using restore engine.
5. Expose helper control/status over XPC service with shared IPC fallback.
6. Enforce entitlement and pause gating on capture/restore paths.
7. Keep behavior channel-neutral except entitlement provider implementation selected by channel.

## Required Runtime Behavior
- On app launch:
  - append lifecycle event
  - attempt restore if eligible
  - capture state if monitoring is active
- On AX event:
  - debounce
  - skip if paused or entitlement cannot monitor
  - capture state
- On pause/inactive entitlement:
  - cancel pending AX capture tasks
  - stop new captures and auto-restore triggers

## Startup + Permissions
- Keep helper LSUIElement behavior.
- Keep helper fully headless (no visible helper UI windows).
- Helper bundle is shipped as embedded login item under the main app (`Contents/Library/LoginItems/OfficeResumeHelper.app`), not as a top-level `/Applications` app.
- Surface Accessibility trust state into daemon status.
- Refresh Accessibility trust state periodically (~2 seconds) and publish status updates without requiring lifecycle events.
- Register and host XPC listener at startup.
- Publish daemon status JSON to shared IPC path.
- Observe distributed notification commands (`pause`, `restore-now`, `clear-snapshot`) and route to controller handlers.

## Forbidden Changes
- Do not perform UI logic in helper.
- Do not bypass restore dedupe or one-shot marker rules.
- Do not capture state when monitoring is explicitly disabled.
- Do not introduce MAS/Direct non-billing behavior drift.

## Component Acceptance Checks
- Launch/terminate events appear in recent event log.
- Pause disables capture and restore triggers.
- Inactive entitlement disables capture and restore triggers.
- AX observer attach/detach behaves correctly across Office relaunches.
- Toggling Accessibility permission while helper is running updates published status quickly.
