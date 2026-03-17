# Menu UI Spec (`Sources/OfficeResumeDirect`, `Sources/OfficeResumeMAS`, `Sources/MenuUIShared`)

## Scope
Menu bar user interface and account surface for helper control and billing.

## Owned Files
- `Sources/OfficeResumeDirect/**`
- `Sources/OfficeResumeMAS/**`
- `Sources/MenuUIShared/**`

## Responsibilities
1. Render a standard dockless macOS menu (`MenuBarExtra` menu style).
2. Render helper availability and paused-state feedback.
3. Render autostart health exactly as:
   - `Autostart: OK` when main app + helper login item are enabled
   - `Autostart: click to fix` (opens Login Items settings) when not healthy
4. Render Accessibility status exactly as:
   - `Accessibility: OK` when trusted
   - `Accessibility: click to fix` (prompts from helper and opens system settings) when not trusted
5. Expose controls:
   - `Restore Now`
   - `Pause Tracking` / `Resume Tracking`
   - `Advanced > Grant Folder Access…`
   - `Advanced > Clear Snapshot`
   - `Advanced > Open Debug Log in Console`
   - `Account…`
   - `Quit`
6. Host one shared compact account window/scene for MAS and Direct.
7. Use XPC for helper commands/status when available; fall back to shared IPC status + distributed command notifications.
8. Set distribution channel marker used by core provider selection, while keeping non-billing runtime behavior unified.

## Menu Behavior
- Menu stays lean and operational.
- Do not show dedicated entitlement rows in the main menu.
- Do not show recent-event lists in the main menu.
- Do not show a dedicated OneNote unsupported row/message.
- Fetch or refresh status on app startup, menu open, file-watch/shared-status updates, and user actions.
- Use bounded retry/backoff while establishing helper connectivity; no always-on 2-second polling loop.
- `Advanced > Grant Folder Access…` opens a directory picker (`NSOpenPanel`) that allows one or more directory roots to be granted for persistent restore access.
- Folder-grant UI is owned by the menu app; no helper UI is introduced.

## Account Window Behavior
### Direct
- Signed-out state:
  - email input
  - `Send Sign-In Link`
  - short pricing/trial explanation
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

### MAS
- Current entitlement/trial summary
- `Refresh Status`
- `Manage Subscription`

## Channel Rules
- Direct target sets channel marker to `direct`.
- MAS target sets channel marker to `mas`.
- UI behavior and menu surface must remain parity across channels except account-provider implementation details.
- Runtime app name/process behavior should be unified as `OfficeResume`.

## Forbidden Changes
- Do not move monitoring/restore logic into UI process.
- Do not add per-app restore policy UI in v1.
- Do not reintroduce persistent Dock presence.
- Do not use `.menuBarExtraStyle(.window)` or custom `NSPopover`/`NSPanel`/custom window-shell menus.

## Component Acceptance Checks
- Controls invoke helper commands via XPC or fallback distributed notifications.
- Autostart line shows `Autostart: OK` when main app + helper login-item registration are healthy.
- Autostart line is clickable (`Autostart: click to fix`) when registration is not healthy.
- Accessibility line shows `Accessibility: OK` when trusted.
- Accessibility line is clickable (`Accessibility: click to fix`) when not trusted.
- Accessibility line updates when permission is granted/revoked while app/helper are running.
- `Advanced > Grant Folder Access…` persists selected directory roots for later restore use by the helper.
- `Account…` opens the shared account window.
- `Quit` terminates helper and menu app together.
- Direct signed-in non-paid users see `Choose Plan…`, which opens the Worker-hosted pricing page.
