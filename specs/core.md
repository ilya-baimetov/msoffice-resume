# Core Module Spec (`Sources/OfficeResumeCore`)

## Scope
Shared business logic and contracts used by the helper and the menu/account UI.

## Owned Files
- `DomainModels.swift`
- `Protocols.swift`
- `Storage.swift`
- `RestoreEngine.swift`
- `OfficeAdapters.swift`
- `Entitlements.swift`
- `DaemonXPCBridge.swift`
- `DaemonSharedIPC.swift`
- `HelperLauncher.swift`
- `RuntimeConfiguration.swift`
- `OfficeBundleRegistry.swift`
- `DebugLog.swift`
- `Tests/OfficeResumeCoreTests/**`

## Responsibilities
1. Define stable shared models and protocol contracts.
2. Persist snapshots, events, and artifact indexes with one direct-only storage policy.
3. Persist shared status, restore markers, entitlements, and debug logs under the same root policy.
4. Compute restore plans with dedupe and one-shot markers.
5. Implement Office adapter scripting boundaries.
6. Provide helpers for AX-driven reconciliation scheduling and sparse safety-sweep policy.
7. Implement Direct entitlement and account abstractions plus session persistence.
8. Maintain XPC DTO compatibility and shared IPC fallback compatibility.

## Model Requirements
- `DocumentSnapshot.canonicalPath` is optional.
- Decoding transparently normalizes prior `""` or placeholder path values to `nil`.
- `AppSnapshot` does not embed restore-attempt state.
- Restore markers live in dedicated storage.

## Adapter Requirements
- Word, Excel, and PowerPoint fetch document lists using Office scripting.
- Word, Excel, and PowerPoint restore opens only snapshot paths passed in the restore plan.
- Word, Excel, and PowerPoint untitled handling attempts real force-save to `unsaved/` artifacts, then indexes persisted paths.
- Outlook restore is activate or relaunch only; no message-level reconstruction.
- OneNote adapter remains unsupported.
- Adapter APIs assume AX decides when reconciliation should occur; adapters do not own event monitoring.

## Entitlement and Account Requirements
- Provide Direct entitlement provider and Direct account provider behind shared interfaces.
- Cache and apply 7-day offline grace behavior.
- Production path uses verified backend auth and Keychain-backed session handling.
- Shared account state surfaces an optional billing action (`subscribe` or `manageSubscription`).
- Billing action resolution comes from the backend so paid, unpaid, and free-pass states remain server-authoritative.
- Any local bypass is debug-only, compile-time gated, explicit, and non-default.
- Hard-coded friends-and-family free-pass emails belong on the backend side only.

## Direct-Only Requirements
- Do not add MAS-specific storage, restore, or UI behavior in core.
- Do not reintroduce sandbox-first storage assumptions into the active contract.
- Keep helper and menu shared status focused on operational state, including Accessibility status.

## Forbidden Changes
- Do not introduce remote telemetry.
- Do not add OneNote restore behavior.
- Do not reintroduce tight scripting loops as the primary capture model.
- Do not re-enable production local free-pass override paths.
- Do not store production Direct sessions only in environment variables.

## Component Acceptance Checks
- `OfficeResumeCoreTests` passes.
- Storage root selection is deterministic.
- Shared auxiliary files use the unified direct-only root.
- Unsaved force-save path stores only artifacts that actually exist.
- Optional-path migration is backward-compatible with old snapshot data.
- XPC status DTO changes are reflected in menu UI consumers.
- Shared IPC status and command fallback works across the process boundary.
