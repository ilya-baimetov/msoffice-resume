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
3. Render Accessibility status exactly as:
   - `Accessibility: OK` when trusted
   - `Accessibility: click to fix` (opens system Accessibility settings) when not trusted
4. Expose controls:
   - `Restore Now`
   - `Pause Tracking` / `Resume Tracking`
   - `Advanced > Clear Snapshot`
   - `Advanced > Open Debug Log in Console`
   - `Quit`
5. Use XPC for helper commands/status when available; fall back to shared IPC status + distributed command notifications.
6. Initialize distribution channel marker for helper/core selection.

## Channel Rules
- Direct target sets channel marker to `direct`.
- MAS target sets channel marker to `mas`.
- UI behavior is otherwise feature-parity for v1 controls and driven by shared UI implementation.

## Forbidden Changes
- Do not move monitoring/restore logic into UI process.
- Do not add per-app restore policy UI in v1.
- Do not reintroduce persistent Dock presence for menu app targets.
- Do not use `.menuBarExtraStyle(.window)` or custom `NSPopover`/`NSPanel`/`NSWindow` menu shells.
- Do not show a dedicated OneNote unsupported row/message in the menu UI.

## Component Acceptance Checks
- Controls invoke helper commands via XPC or fallback distributed notifications.
- Accessibility line shows `Accessibility: OK` when trusted.
- Accessibility line is clickable (`Accessibility: click to fix`) when not trusted.
- Accessibility line updates when permission is granted/revoked while app/helper are already running.
- `Quit` terminates helper and menu app together.
