# Core Module Spec (`Sources/OfficeResumeCore`)

## Scope
Shared business logic and contracts used by helper and menu UI.

## Owned Files
- `DomainModels.swift`
- `Protocols.swift`
- `Storage.swift`
- `RestoreEngine.swift`
- `OfficeAdapters.swift`
- `Entitlements.swift`
- `DaemonXPCBridge.swift`
- `HelperLauncher.swift`
- `RuntimeConfiguration.swift`
- `OfficeBundleRegistry.swift`
- `DebugLog.swift`
- `Tests/OfficeResumeCoreTests/**`

## Responsibilities
1. Define stable shared models and protocol contracts.
2. Persist snapshots/events/artifact index with unified app-group-first storage policy.
3. Compute restore plans with dedupe + one-shot markers.
4. Implement Office adapter scripting boundaries.
5. Implement entitlement abstraction + channel-specific providers.
6. Maintain XPC DTO compatibility and shared IPC fallback compatibility.

## Adapter Requirements
- W/E/P fetch document list using AppleScript.
- W/E/P restore opens only snapshot paths passed in plan.
- W/E/P untitled handling attempts real force-save to `unsaved/` artifacts, then index persisted paths.
- Outlook restore is activate/relaunch-only; no message-level reconstruction.
- OneNote adapter remains unsupported.

## Entitlement Requirements
- Provide `StoreKitEntitlementProvider` and `StripeEntitlementProvider` behind `EntitlementProvider`.
- Cache and apply 7-day offline grace behavior.
- Keep free-pass logic backend-authoritative in production Direct path.
- Any local free-pass bypass must be debug-only, explicit, and non-default.

## Channel Unification Requirements
- Keep non-billing behavior unified across MAS and Direct.
- Keep runtime name/process behavior aligned across app targets.
- Do not add channel-specific storage, restore, or UI logic in core.

## Forbidden Changes
- Do not introduce remote telemetry.
- Do not add OneNote restore behavior.
- Do not reintroduce polling-only restore/capture paths.
- Do not re-enable production local free-pass override paths.

## Component Acceptance Checks
- `OfficeResumeCoreTests` passes.
- Storage root selection is app-group-first and deterministic.
- Unsaved force-save path stores only artifacts that actually exist.
- XPC status DTO changes are reflected in menu UI consumers.
- Shared IPC status and command fallback works across process boundary.
