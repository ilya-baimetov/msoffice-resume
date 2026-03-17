# Core Module Spec (`Sources/OfficeResumeCore`)

## Scope
Shared business logic and contracts used by helper and menu/account UI.

## Owned Files
- `DomainModels.swift`
- `Protocols.swift`
- `Storage.swift`
- `FolderAccess.swift`
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
2. Persist snapshots/events/artifact index with unified app-group-first storage policy.
3. Persist shared status, restore markers, entitlements, debug logs, and folder-access bookmarks under the same root policy.
4. Compute restore plans with dedupe + one-shot markers.
5. Implement Office adapter scripting boundaries.
6. Provide helpers for lifecycle-driven capture, bounded launch/restore warm-up retries, and bounded frontmost refresh decisions.
7. Implement entitlement abstraction plus channel-specific providers.
8. Implement shared account/billing abstractions and Direct session persistence.
9. Persist and resolve security-scoped folder bookmarks for sandbox-safe restore.
10. Maintain XPC DTO compatibility and shared IPC fallback compatibility.

## Model Requirements
- `DocumentSnapshot.canonicalPath` is optional.
- Decoding must transparently normalize prior `""`/placeholder path values to `nil`.
- `AppSnapshot` does not embed restore-attempt state.
- Restore markers live in dedicated storage.
- Folder-access bookmark records must preserve stable root-path matching data plus bookmark payload.

## Adapter Requirements
- W/E/P fetch document list using AppleScript.
- W/E/P restore opens only snapshot paths passed in plan.
- W/E/P restore must run inside any matching security-scoped folder access established by the helper.
- W/E/P untitled handling attempts real force-save to `unsaved/` artifacts, then index persisted paths.
- Outlook restore is activate/relaunch-only; no message-level reconstruction.
- OneNote adapter remains unsupported.

## Entitlement and Account Requirements
- Provide `StoreKitEntitlementProvider` and `StripeEntitlementProvider` behind `EntitlementProvider`.
- Provide shared account providers for MAS and Direct.
- Cache and apply 7-day offline grace behavior.
- Direct production path must use verified backend auth and Keychain-backed session handling.
- Shared account state must surface an optional billing action (`subscribe` or `manageSubscription`) instead of assuming one subscription-management URL.
- Direct billing action resolution must come from the backend so paid, unpaid, and free-pass states remain server-authoritative.
- Any local bypass must be debug-only, compile-time gated, explicit, and non-default.
- Hard-coded friends-and-family free-pass emails belong on the backend side only.

## Channel Unification Requirements
- Keep non-billing behavior unified across MAS and Direct.
- Keep runtime name/process behavior aligned across app targets.
- Do not add channel-specific storage, restore, or UI behavior in core.
- Keep the sandboxed folder-grant model identical across MAS and Direct.
- Keep helper/menu shared status free of Accessibility/TCC state.

## Forbidden Changes
- Do not introduce remote telemetry.
- Do not add OneNote restore behavior.
- Do not reintroduce broad always-on polling-only capture paths.
- Do not re-enable production local free-pass override paths.
- Do not store production Direct sessions only in environment variables.

## Component Acceptance Checks
- `OfficeResumeCoreTests` passes.
- Storage root selection is app-group-first and deterministic.
- Shared auxiliary files (status, restore markers, logs, entitlements, folder grants) use the unified root.
- Unsaved force-save path stores only artifacts that actually exist.
- Optional-path migration is backward-compatible with old snapshot data.
- Folder bookmark persistence and path-to-root matching are deterministic.
- XPC status DTO changes are reflected in menu UI consumers.
- Shared IPC status and command fallback works across process boundary.
