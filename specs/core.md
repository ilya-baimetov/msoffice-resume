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
2. Persist snapshots/events/artifact index with channel-aware storage paths.
3. Compute restore plans with dedupe + one-shot markers.
4. Implement Office adapter scripting boundaries.
5. Implement entitlement provider abstractions and channel-aware provider factory.
6. Maintain XPC DTO encoding/decoding compatibility.

## Adapter Requirements
- W/E/P fetch document list using AppleScript.
- W/E/P restore opens only snapshot paths passed in plan.
- W/E/P untitled handling must attempt real force-save to `unsaved/` artifacts, then index persisted paths.
- Outlook restore is activate/relaunch-only; no message-level reconstruction.
- OneNote adapter remains unsupported.

## Entitlement Requirements
- Provide `StoreKitEntitlementProvider` and `StripeEntitlementProvider` behind `EntitlementProvider`.
- Cache and apply offline grace behavior.
- Support free-pass/local override path for local testing.

## Forbidden Changes
- Do not introduce remote telemetry.
- Do not add OneNote restore behavior.
- Do not reintroduce polling-only restore/capture paths.

## Component Acceptance Checks
- `OfficeResumeCoreTests` passes.
- Storage path selection is deterministic per channel.
- Unsaved force-save path only stores artifacts that actually exist.
- XPC status DTO changes are reflected in menu UI consumers.
