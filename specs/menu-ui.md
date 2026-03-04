# Menu UI Spec (`Sources/OfficeResumeDirect`, `Sources/OfficeResumeMAS`)

## Scope
Menu bar user interface and command surface for helper control.

## Owned Files
- `Sources/OfficeResumeDirect/**`
- `Sources/OfficeResumeMAS/**`

## Responsibilities
1. Render helper connection status.
2. Render entitlement status summary from daemon status.
3. Render Accessibility status + settings action when needed.
4. Expose controls:
   - `Restore now`
   - `Pause tracking`
   - `Clear snapshot`
   - `Quit Office Resume`
5. Render recent event list and snapshot summary.
6. Initialize distribution channel marker for helper/core selection.

## Channel Rules
- Direct target sets channel marker to `direct`.
- MAS target sets channel marker to `mas`.
- UI behavior is otherwise feature-parity for v1 controls.

## Forbidden Changes
- Do not move monitoring/restore logic into UI process.
- Do not hide OneNote unsupported status.
- Do not add per-app restore policy UI in v1.

## Component Acceptance Checks
- Controls invoke corresponding XPC commands.
- Entitlement label updates for active/inactive/trial and plan types.
- Accessibility warning and remediation link appear when not trusted.
