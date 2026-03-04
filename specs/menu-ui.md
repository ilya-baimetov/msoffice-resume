# Menu UI Spec (`Sources/OfficeResumeDirect`, `Sources/OfficeResumeMAS`)

## Scope
Menu bar user interface and command surface for helper control.

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
   - `Accessibility: click to fix` (opens system Accessibility settings) when not trusted
5. Expose controls:
   - `Restore Now`
   - `Pause Tracking` / `Resume Tracking`
   - `Advanced > Clear Snapshot`
   - `Advanced > Open Debug Log in Console`
   - `Quit`
6. Use XPC for helper commands/status when available; fall back to shared IPC status + distributed command notifications.
7. Set distribution channel marker used by core entitlement selection, while keeping non-billing runtime behavior unified.

## Channel Rules
- Direct target sets channel marker to `direct`.
- MAS target sets channel marker to `mas`.
- UI behavior and menu surface must remain parity across channels.
- Runtime app name/process behavior should be unified as `OfficeResume`.

## Forbidden Changes
- Do not move monitoring/restore logic into UI process.
- Do not add per-app restore policy UI in v1.
- Do not reintroduce persistent Dock presence.
- Do not use `.menuBarExtraStyle(.window)` or custom `NSPopover`/`NSPanel`/`NSWindow` menu shells.
- Do not show a dedicated OneNote unsupported row/message in the menu UI.

## Component Acceptance Checks
- Controls invoke helper commands via XPC or fallback distributed notifications.
- Autostart line shows `Autostart: OK` when main app + helper login-item registration are healthy.
- Autostart line is clickable (`Autostart: click to fix`) when registration is not healthy.
- Accessibility line shows `Accessibility: OK` when trusted.
- Accessibility line is clickable (`Accessibility: click to fix`) when not trusted.
- Accessibility line updates when permission is granted/revoked while app/helper are running.
- `Quit` terminates helper and menu app together.
