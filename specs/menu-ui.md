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
3. Render Accessibility status + settings action when needed.
4. Expose controls:
   - `Restore Now`
   - `Pause Tracking` / `Resume Tracking`
   - `Advanced > Clear Snapshot`
   - `Advanced > Open Debug Log in Console`
   - `Quit`
5. Initialize distribution channel marker for helper/core selection.

## Channel Rules
- Direct target sets channel marker to `direct`.
- MAS target sets channel marker to `mas`.
- UI behavior is otherwise feature-parity for v1 controls and driven by shared UI implementation.

## Forbidden Changes
- Do not move monitoring/restore logic into UI process.
- Do not add per-app restore policy UI in v1.
- Do not reintroduce persistent Dock presence for menu app targets.
- Do not show a dedicated OneNote unsupported row/message in the menu UI.

## Component Acceptance Checks
- Controls invoke corresponding XPC commands.
- Accessibility warning and remediation link appear when not trusted.
- `Quit` terminates helper and menu app together.
