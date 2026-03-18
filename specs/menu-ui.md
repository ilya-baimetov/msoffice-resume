# Menu UI Spec (`Sources/OfficeResumeDirect`, `Sources/MenuUIShared`)

## Scope
Menu bar user interface and account surface for helper control and billing.

## Owned Files
- `Sources/OfficeResumeDirect/**`
- `Sources/MenuUIShared/**`

Legacy note:
- `Sources/OfficeResumeMAS/**` may remain temporarily in the repository, but it is not part of the active product contract.

## Responsibilities
1. Render a standard dockless macOS menu using `MenuBarExtra` menu style.
2. Render helper availability and paused-state feedback.
3. Render Accessibility health exactly as:
   - `Accessibility: OK` when AX permission is available
   - `Accessibility: click to fix` when not available
4. Render autostart health exactly as:
   - `Autostart: OK` when main app and helper login item are enabled
   - `Autostart: click to fix` when not healthy
5. Expose controls:
   - `Restore Now`
   - `Pause Tracking` or `Resume Tracking`
   - `Advanced > Clear Snapshot`
   - `Advanced > Open Debug Log in Console`
   - `Account…`
   - `Quit`
6. Host one shared compact account window for Direct.
7. Use XPC for helper commands and status when available; fall back to shared IPC status plus distributed command notifications.
8. Set the Direct channel marker used by core provider selection.

## Menu Behavior
- Menu stays lean and operational.
- Do not show dedicated entitlement rows in the main menu.
- Do not show recent-event lists in the main menu.
- Do not show a dedicated OneNote unsupported row or message.
- Fetch or refresh status on app startup, menu open, shared-status updates, and user actions.
- Use bounded retry and backoff while establishing helper connectivity.
- `Accessibility: click to fix` asks the helper to request trust for its own process and opens the relevant System Settings pane if needed.
- `Autostart: click to fix` opens Login Items settings.

## Account Window Behavior
### Direct
- Signed-out state:
  - email input
  - `Send Sign-In Link`
  - short pricing and trial explanation
  - message that verified email is required
- Signed-in state:
  - signed-in email
  - current entitlement summary
  - `Refresh Status`
  - one context-sensitive billing action:
    - `Choose Plan…` for signed-in non-paid users
    - `Manage Subscription` for paid users
    - no paid action for free-pass users
  - `Sign Out`
- Debug builds may expose explicit local testing shortcuts when runtime opt-in is enabled.

## Direct Rules
- Direct target sets channel marker to `direct`.
- Runtime app name and process behavior should be unified as `Office Resume`.
- Accessibility state is first-class operational UI because AX is required.

## Forbidden Changes
- Do not move monitoring or restore logic into the UI process.
- Do not add per-app restore policy UI in v1.
- Do not reintroduce persistent Dock presence.
- Do not use `.menuBarExtraStyle(.window)` or custom `NSPopover` or panel-based menus.

## Component Acceptance Checks
- Controls invoke helper commands via XPC or fallback distributed notifications.
- Accessibility line shows `Accessibility: OK` when trusted.
- Accessibility line is clickable as `Accessibility: click to fix` when not trusted.
- Autostart line shows `Autostart: OK` when main app and helper login-item registration are healthy.
- Autostart line is clickable as `Autostart: click to fix` when registration is not healthy.
- `Account…` opens the shared account window.
- `Quit` terminates the helper and the menu app together.
- Direct signed-in non-paid users see `Choose Plan…`, which opens the Worker-hosted pricing page.
