import AppKit
import Foundation
import IOKit.ps
import OfficeResumeCore

final class OfficeLifecycleMonitor {
    typealias AppCallback = (OfficeApp, LifecycleEventType, NSRunningApplication?) -> Void

    private var observers: [NSObjectProtocol] = []
    private let appCallback: AppCallback
    private let sessionDidResignActiveCallback: () -> Void

    init(
        appCallback: @escaping AppCallback,
        sessionDidResignActiveCallback: @escaping () -> Void
    ) {
        self.appCallback = appCallback
        self.sessionDidResignActiveCallback = sessionDidResignActiveCallback
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handle(notification: notification, type: .appLaunched)
        }

        let activated = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handle(notification: notification, type: .appActivated)
        }

        let deactivated = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handle(notification: notification, type: .appDeactivated)
        }

        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handle(notification: notification, type: .appTerminated)
        }

        let sessionResigned = center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.sessionDidResignActiveCallback()
        }

        observers = [launched, activated, deactivated, terminated, sessionResigned]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handle(notification: Notification, type: LifecycleEventType) {
        guard
            let runningApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let mapped = OfficeBundleRegistry.app(for: runningApp.bundleIdentifier)
        else {
            return
        }

        appCallback(mapped, type, runningApp)
    }
}

private enum PowerSourceKind {
    case powerAdapter
    case battery

    static func current() -> PowerSourceKind {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providedType = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        return providedType == kIOPSACPowerValue ? .powerAdapter : .battery
    }
}

@MainActor
final class HelperDaemonController {
    private enum DefaultsKey {
        static let isPaused = "com.pragprod.msofficeresume.isPaused"
    }

    private let stateStore: DaemonStateStore
    private let snapshotStore: SnapshotStore
    private let folderAccessStore: FolderAccessStore
    private let restoreEngine: RestoreEngine
    private let entitlementProvider: EntitlementProvider
    private let adapters: [OfficeApp: OfficeAdapter]
    private let userDefaults: UserDefaults

    private var isPaused: Bool
    private var observedLaunchIDs: [OfficeApp: String] = [:]
    private var observedLaunchFirstSeenAt: [OfficeApp: Date] = [:]
    private var pendingCaptureTasks: [OfficeApp: Task<Void, Never>] = [:]
    private var frontmostRefreshTask: Task<Void, Never>?
    private var frontmostRefreshApp: OfficeApp?

    private let deactivateCaptureDebounceNanoseconds: UInt64 = 350_000_000
    private let powerAdapterRefreshNanoseconds: UInt64 = 1_000_000_000
    private let batteryRefreshNanoseconds: UInt64 = 10_000_000_000
    private let emptySnapshotProtectionWindow: TimeInterval = 60

    init(
        channel: StorageChannel? = nil,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaults() ?? .standard
    ) throws {
        let stateStore = DaemonStateStore()
        let distributionChannel = RuntimeConfiguration.distributionChannel(userDefaults: userDefaults)
        let resolvedChannel = channel ?? RuntimeConfiguration.storageChannel(for: distributionChannel)
        let snapshotStore = FileSnapshotStore(channel: resolvedChannel)
        let folderAccessStore = FolderAccessStore()
        let markerStore = try FileRestoreMarkerStore()
        let entitlementStore = try EntitlementFileStore()

        self.stateStore = stateStore
        self.snapshotStore = snapshotStore
        self.folderAccessStore = folderAccessStore
        self.restoreEngine = RestoreEngine(snapshotStore: snapshotStore, markerStore: markerStore)
        self.entitlementProvider = EntitlementProviderFactory.makeProvider(
            channel: distributionChannel,
            store: entitlementStore
        )
        self.adapters = OfficeAdapterFactory.makeDefaultAdapters(snapshotStore: snapshotStore)
        self.userDefaults = userDefaults

        isPaused = userDefaults.bool(forKey: DefaultsKey.isPaused)

        _ = stateStore.setPaused(isPaused)
        stateStore.setHelperRunning(true)
        publishStatus()

        DebugLog.info(
            "Helper daemon initialized",
            metadata: [
                "paused": isPaused ? "true" : "false",
                "channel": distributionChannel.rawValue,
            ]
        )
    }

    func start() {
        DebugLog.info("Helper daemon starting")

        Task { @MainActor in
            await refreshEntitlementStatus()
            await syncSnapshotTimestamps()
            await restoreRunningAppsAtStartup()
            await captureRunningAppsAtStartup()
            await startFrontmostRefreshForCurrentFrontmostApp(reason: "startup")
        }
    }

    func stop() {
        DebugLog.info("Helper daemon stopping")
        cancelPendingCaptures()
        stopFrontmostRefresh()
        stateStore.setHelperRunning(false)
        publishStatus()
    }

    func makeXPCHandlers() -> DaemonServiceHandlers {
        DaemonServiceHandlers(
            getStatus: { [weak self] in
                self?.status() ?? DaemonStatusDTO(
                    isPaused: true,
                    helperRunning: false,
                    entitlementActive: false,
                    entitlementPlan: .none,
                    entitlementValidUntil: nil,
                    entitlementTrialEndsAt: nil,
                    latestSnapshotCapturedAt: [:],
                    unsupportedApps: OfficeBundleRegistry.unsupportedApps
                )
            },
            setPaused: { [weak self] paused in
                await self?.setPaused(paused) ?? false
            },
            restoreNow: { [weak self] app in
                await self?.restoreNow(app: app) ?? RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 0)
            },
            clearSnapshot: { [weak self] app in
                await self?.clearSnapshot(app: app) ?? false
            }
        )
    }

    func handleLifecycleEvent(app: OfficeApp, type: LifecycleEventType, runningApplication: NSRunningApplication?) {
        let details = lifecycleDetails(type: type, runningApplication: runningApplication)
        DebugLog.debug(
            "Lifecycle event received",
            metadata: [
                "app": app.rawValue,
                "event": type.rawValue,
                "pid": details["pid"] ?? "",
            ]
        )

        Task { @MainActor in
            let event = LifecycleEvent(app: app, type: type, timestamp: Date(), details: details)
            try? await snapshotStore.appendEvent(event)

            guard app != .onenote else {
                if type == .appTerminated || type == .appDeactivated {
                    stopFrontmostRefreshIfNeeded(for: app)
                }
                return
            }

            switch type {
            case .appLaunched:
                await restoreAfterLaunchIfNeeded(app: app, runningApplication: runningApplication)
                guard await canCaptureState() else {
                    return
                }
                await captureAppState(app: app, source: "launch")
                await startFrontmostRefreshIfNeeded(for: app, reason: "launch")
            case .appActivated:
                guard await canCaptureState() else {
                    return
                }
                await captureAppState(app: app, source: "activate")
                await startFrontmostRefreshIfNeeded(for: app, reason: "activate")
            case .appDeactivated:
                stopFrontmostRefreshIfNeeded(for: app)
                guard await canCaptureState() else {
                    return
                }
                scheduleCapture(app: app, source: "deactivate", after: deactivateCaptureDebounceNanoseconds)
            case .appTerminated:
                stopFrontmostRefreshIfNeeded(for: app)
                pendingCaptureTasks[app]?.cancel()
                pendingCaptureTasks.removeValue(forKey: app)
            case .stateCaptured, .restoreStarted, .restoreSucceeded, .restoreFailed:
                break
            }
        }
    }

    func handleSessionDidResignActive() {
        Task { @MainActor in
            stopFrontmostRefresh()
            guard await canCaptureState() else {
                return
            }

            for app in supportedCaptureApps() {
                guard isAppRunning(app) else {
                    continue
                }
                await captureAppState(app: app, source: "session")
            }
        }
    }

    func handleCommandSetPaused(_ paused: Bool) async {
        _ = await setPaused(paused)
    }

    func handleCommandRestoreNow(appRaw: String?) async {
        let app = appRaw.flatMap { OfficeApp(rawValue: $0) }
        _ = await restoreNow(app: app)
    }

    func handleCommandClearSnapshot(appRaw: String?) async {
        let app = appRaw.flatMap { OfficeApp(rawValue: $0) }
        _ = await clearSnapshot(app: app)
    }

    func handleCommandRefreshEntitlement() async {
        await refreshEntitlementStatus()
    }

    private func status() -> DaemonStatusDTO {
        stateStore.currentStatus()
    }

    private func setPaused(_ paused: Bool) async -> Bool {
        isPaused = paused
        userDefaults.set(paused, forKey: DefaultsKey.isPaused)
        if paused {
            cancelPendingCaptures()
            stopFrontmostRefresh()
        }
        let ok = stateStore.setPaused(paused)
        publishStatus()
        if !paused {
            await startFrontmostRefreshForCurrentFrontmostApp(reason: "resume")
        }
        DebugLog.info("Pause state updated", metadata: ["paused": paused ? "true" : "false", "ok": ok ? "true" : "false"])
        return ok
    }

    private func restoreNow(app: OfficeApp?) async -> RestoreCommandResultDTO {
        await refreshEntitlementStatus()

        guard await entitlementProvider.canRestore() else {
            return RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 0)
        }

        if let app {
            let result = await performRestore(app: app, source: "manual")
            await startFrontmostRefreshIfNeeded(for: app, reason: "manual-restore")
            return result
        }

        var restoredCount = 0
        var failedCount = 0

        for app in OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps {
            let result = await performRestore(app: app, source: "manual")
            restoredCount += result.restoredCount
            failedCount += result.failedCount
        }

        await startFrontmostRefreshForCurrentFrontmostApp(reason: "manual-restore")

        return RestoreCommandResultDTO(
            succeeded: failedCount == 0,
            restoredCount: restoredCount,
            failedCount: failedCount
        )
    }

    private func clearSnapshot(app: OfficeApp?) async -> Bool {
        do {
            try await snapshotStore.clearSnapshot(for: app)
            try await restoreEngine.clearMarkers(for: app)
            await syncSnapshotTimestamps()
            return true
        } catch {
            return false
        }
    }

    private func restoreAfterLaunchIfNeeded(app: OfficeApp, runningApplication: NSRunningApplication?) async {
        await refreshEntitlementStatus()

        guard !isPaused else {
            return
        }

        guard await entitlementProvider.canRestore() else {
            return
        }

        guard OfficeBundleRegistry.automaticRestoreApps.contains(app) else {
            DebugLog.debug(
                "Automatic restore skipped for lifecycle-only app",
                metadata: ["app": app.rawValue]
            )
            return
        }

        _ = await performRestore(app: app, source: "relaunch", runningApplication: runningApplication)
        await startFrontmostRefreshIfNeeded(for: app, reason: "relaunch")
    }

    private func performRestore(
        app: OfficeApp,
        source: String,
        runningApplication: NSRunningApplication? = nil
    ) async -> RestoreCommandResultDTO {
        guard app != .onenote else {
            return RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 0)
        }

        guard let adapter = adapters[app] else {
            return RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 0)
        }

        let launchID = launchInstanceID(for: app, runningApplication: runningApplication)

        do {
            let currentDocs: [DocumentSnapshot]
            if OfficeBundleRegistry.documentRestoreApps.contains(app) {
                let currentState = try await adapter.fetchState()
                currentDocs = currentState.documents
            } else {
                currentDocs = []
            }

            guard let plan = try await restoreEngine.buildPlan(
                for: app,
                launchInstanceID: launchID,
                currentlyOpenDocuments: currentDocs
            ) else {
                DebugLog.debug(
                    "Restore skipped (no plan)",
                    metadata: ["app": app.rawValue, "source": source, "launchID": launchID]
                )
                return RestoreCommandResultDTO(succeeded: true, restoredCount: 0, failedCount: 0)
            }

            DebugLog.info(
                "Restore plan created",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                    "launchID": launchID,
                    "documentsToOpen": "\(plan.documentsToOpen.count)",
                ]
            )

            try await snapshotStore.appendEvent(
                LifecycleEvent(app: app, type: .restoreStarted, timestamp: Date(), details: ["source": source, "launch": launchID])
            )

            let restoreSnapshot = AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: Date(),
                documents: plan.documentsToOpen,
                windowsMeta: []
            )

            let accessSession: FolderAccessSession?
            do {
                accessSession = try await folderAccessStore.beginAccess(
                    for: restoreSnapshot.documents.compactMap(\.canonicalPath)
                )
            } catch {
                DebugLog.warning(
                    "Folder access session could not be established before restore",
                    metadata: [
                        "app": app.rawValue,
                        "source": source,
                        "error": error.localizedDescription,
                    ]
                )
                accessSession = nil
            }
            defer { accessSession?.end() }

            let restoreResult = try await adapter.restore(snapshot: restoreSnapshot)
            try await restoreEngine.markRestoreCompleted(app: app, launchInstanceID: launchID)

            if restoreResult.failedPaths.isEmpty {
                DebugLog.info(
                    "Restore succeeded",
                    metadata: [
                        "app": app.rawValue,
                        "source": source,
                        "restored": "\(restoreResult.restoredPaths.count)",
                    ]
                )
                try await snapshotStore.appendEvent(
                    LifecycleEvent(
                        app: app,
                        type: .restoreSucceeded,
                        timestamp: Date(),
                        details: ["source": source, "restored": "\(restoreResult.restoredPaths.count)"]
                    )
                )
            } else {
                DebugLog.warning(
                    "Restore partially failed",
                    metadata: [
                        "app": app.rawValue,
                        "source": source,
                        "restored": "\(restoreResult.restoredPaths.count)",
                        "failed": "\(restoreResult.failedPaths.count)",
                    ]
                )
                try await snapshotStore.appendEvent(
                    LifecycleEvent(
                        app: app,
                        type: .restoreFailed,
                        timestamp: Date(),
                        details: [
                            "source": source,
                            "restored": "\(restoreResult.restoredPaths.count)",
                            "failed": "\(restoreResult.failedPaths.count)",
                        ]
                    )
                )
            }

            return RestoreCommandResultDTO(
                succeeded: restoreResult.failedPaths.isEmpty,
                restoredCount: restoreResult.restoredPaths.count,
                failedCount: restoreResult.failedPaths.count
            )
        } catch {
            DebugLog.error(
                "Restore failed",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                    "launchID": launchID,
                    "error": error.localizedDescription,
                ]
            )
            try? await snapshotStore.appendEvent(
                LifecycleEvent(
                    app: app,
                    type: .restoreFailed,
                    timestamp: Date(),
                    details: ["source": source, "error": error.localizedDescription]
                )
            )
            return RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 1)
        }
    }

    private func captureAppState(app: OfficeApp, source: String) async {
        pendingCaptureTasks[app] = nil

        guard await canCaptureState() else {
            return
        }

        guard let adapter = adapters[app], app != .onenote else {
            return
        }

        do {
            var snapshot = try await adapter.fetchState()

            if OfficeBundleRegistry.documentRestoreApps.contains(app) {
                let artifacts = try await adapter.forceSaveUntitled(state: snapshot)
                if !artifacts.isEmpty {
                    let persistedDocs = snapshot.documents.filter { $0.isSaved && $0.canonicalPath != nil }
                    snapshot = AppSnapshot(
                        app: snapshot.app,
                        launchInstanceID: snapshot.launchInstanceID,
                        capturedAt: snapshot.capturedAt,
                        documents: dedupeDocuments(persistedDocs + artifacts),
                        windowsMeta: snapshot.windowsMeta
                    )
                }
            }

            observeLaunch(app: app, launchID: snapshot.launchInstanceID)

            let current = try await snapshotStore.loadSnapshot(for: app)
            if shouldPersist(newSnapshot: snapshot, currentSnapshot: current, app: app, source: source) {
                try await snapshotStore.saveSnapshot(snapshot)
                stateStore.updateLatestSnapshot(app: app, capturedAt: snapshot.capturedAt)
                publishStatus()
                DebugLog.debug(
                    "Snapshot persisted",
                    metadata: [
                        "app": app.rawValue,
                        "source": source,
                        "documents": "\(snapshot.documents.count)",
                    ]
                )
            }

            if OfficeBundleRegistry.documentRestoreApps.contains(app) {
                let referenced = Set(snapshot.documents.compactMap(\.canonicalPath))
                try await snapshotStore.purgeUnreferencedArtifacts(for: app, referencedPaths: referenced)
            }

            let details = ["source": source, "documents": "\(snapshot.documents.count)"]
            try await snapshotStore.appendEvent(LifecycleEvent(app: app, type: .stateCaptured, timestamp: Date(), details: details))
        } catch {
            DebugLog.error(
                "State capture failed",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                    "error": error.localizedDescription,
                ]
            )
            try? await snapshotStore.appendEvent(
                LifecycleEvent(
                    app: app,
                    type: .stateCaptured,
                    timestamp: Date(),
                    details: ["source": source, "error": error.localizedDescription]
                )
            )
        }
    }

    private func captureRunningAppsAtStartup() async {
        guard await canCaptureState() else {
            return
        }

        for app in supportedCaptureApps() {
            guard isAppRunning(app) else {
                continue
            }
            await captureAppState(app: app, source: "startup")
        }
    }

    private func restoreRunningAppsAtStartup() async {
        guard !isPaused else {
            return
        }

        guard await entitlementProvider.canRestore() else {
            return
        }

        for app in OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps {
            guard let runningApplication = runningApplication(for: app) else {
                continue
            }

            _ = await performRestore(app: app, source: "startup", runningApplication: runningApplication)
        }
    }

    private func observeLaunch(app: OfficeApp, launchID: String) {
        guard observedLaunchIDs[app] != launchID else {
            return
        }

        observedLaunchIDs[app] = launchID
        observedLaunchFirstSeenAt[app] = Date()
        DebugLog.debug(
            "Observed launch instance",
            metadata: [
                "app": app.rawValue,
                "launchID": launchID,
            ]
        )
    }

    private func refreshEntitlementStatus() async {
        do {
            let state = try await entitlementProvider.refresh()
            stateStore.setEntitlementState(state)
            publishStatus()
            if !state.isActive {
                cancelPendingCaptures()
                stopFrontmostRefresh()
            } else if !isPaused {
                await startFrontmostRefreshForCurrentFrontmostApp(reason: "entitlement-refresh")
            }
            DebugLog.debug(
                "Entitlement refreshed",
                metadata: [
                    "active": state.isActive ? "true" : "false",
                    "plan": state.plan.rawValue,
                ]
            )
        } catch {
            let state = await entitlementProvider.currentState()
            stateStore.setEntitlementState(state)
            publishStatus()
            if !state.isActive {
                cancelPendingCaptures()
                stopFrontmostRefresh()
            }
            DebugLog.warning(
                "Entitlement refresh failed; using current state",
                metadata: [
                    "active": state.isActive ? "true" : "false",
                    "plan": state.plan.rawValue,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func syncSnapshotTimestamps() async {
        let timestamps = (try? await snapshotStore.latestSnapshotCapturedAt()) ?? [:]
        stateStore.setLatestSnapshots(timestamps)
        publishStatus()
    }

    private func lifecycleDetails(type: LifecycleEventType, runningApplication: NSRunningApplication?) -> [String: String] {
        var details: [String: String] = ["event": type.rawValue]
        if let runningApplication {
            details["pid"] = "\(runningApplication.processIdentifier)"
            if let launchDate = runningApplication.launchDate {
                details["launchDate"] = ISO8601DateFormatter().string(from: launchDate)
            }
        }
        return details
    }

    private func shouldPersist(
        newSnapshot: AppSnapshot,
        currentSnapshot: AppSnapshot?,
        app: OfficeApp,
        source: String
    ) -> Bool {
        guard let currentSnapshot else {
            return true
        }

        if shouldSkipEarlyEmptySnapshot(
            newSnapshot: newSnapshot,
            currentSnapshot: currentSnapshot,
            app: app,
            source: source
        ) {
            return false
        }

        if currentSnapshot.documents != newSnapshot.documents {
            return true
        }

        return currentSnapshot.windowsMeta != newSnapshot.windowsMeta
    }

    private func shouldSkipEarlyEmptySnapshot(
        newSnapshot: AppSnapshot,
        currentSnapshot: AppSnapshot,
        app: OfficeApp,
        source: String
    ) -> Bool {
        guard OfficeBundleRegistry.documentRestoreApps.contains(app) else {
            return false
        }

        guard !currentSnapshot.documents.isEmpty else {
            return false
        }

        guard newSnapshot.documents.isEmpty else {
            return false
        }

        guard let firstSeenAt = observedLaunchFirstSeenAt[app] else {
            return false
        }

        let age = Date().timeIntervalSince(firstSeenAt)
        guard age < emptySnapshotProtectionWindow else {
            return false
        }

        DebugLog.debug(
            "Skipped early empty snapshot overwrite",
            metadata: [
                "app": app.rawValue,
                "source": source,
                "ageSeconds": "\(Int(age))",
                "windowSeconds": "\(Int(emptySnapshotProtectionWindow))",
                "launchID": newSnapshot.launchInstanceID,
            ]
        )
        return true
    }

    private func dedupeDocuments(_ documents: [DocumentSnapshot]) -> [DocumentSnapshot] {
        var seen: Set<String> = []
        var output: [DocumentSnapshot] = []

        for doc in documents {
            guard let normalizedPath = normalizedCanonicalPath(doc.canonicalPath) else {
                continue
            }
            if seen.insert(normalizedPath).inserted {
                output.append(
                    DocumentSnapshot(
                        app: doc.app,
                        displayName: doc.displayName,
                        canonicalPath: normalizedPath,
                        isSaved: doc.isSaved,
                        isTempArtifact: doc.isTempArtifact,
                        capturedAt: doc.capturedAt
                    )
                )
            }
        }

        return output
    }

    private func normalizedCanonicalPath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lowered = trimmed.lowercased()
        if lowered == "missing value" || lowered == "missing" || lowered == "null" || lowered == "(null)" || lowered == "<null>" {
            return nil
        }
        return trimmed
    }

    private func launchInstanceID(for app: OfficeApp, runningApplication observedRunningApplication: NSRunningApplication?) -> String {
        if let observedRunningApplication {
            return makeLaunchID(for: observedRunningApplication)
        }

        guard let currentRunningApplication = runningApplication(for: app) else {
            return "unknown"
        }

        return makeLaunchID(for: currentRunningApplication)
    }

    private func makeLaunchID(for app: NSRunningApplication) -> String {
        let launchTimestamp = app.launchDate?.timeIntervalSince1970 ?? 0
        return "\(app.processIdentifier)-\(Int64(launchTimestamp))"
    }

    private func canCaptureState() async -> Bool {
        guard !isPaused else {
            return false
        }

        return await entitlementProvider.canMonitor()
    }

    private func cancelPendingCaptures() {
        for task in pendingCaptureTasks.values {
            task.cancel()
        }
        pendingCaptureTasks.removeAll()
    }

    private func scheduleCapture(app: OfficeApp, source: String, after nanoseconds: UInt64) {
        pendingCaptureTasks[app]?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if nanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            }

            guard await self.canCaptureState() else {
                return
            }

            await self.captureAppState(app: app, source: source)
        }

        pendingCaptureTasks[app] = task
    }

    private func startFrontmostRefreshForCurrentFrontmostApp(reason: String) async {
        guard let app = frontmostSupportedApp() else {
            stopFrontmostRefresh()
            return
        }

        await startFrontmostRefreshIfNeeded(for: app, reason: reason)
    }

    private func startFrontmostRefreshIfNeeded(for app: OfficeApp, reason: String) async {
        guard supportedCaptureApps().contains(app) else {
            return
        }
        guard await canCaptureState() else {
            return
        }
        guard isAppFrontmost(app), isAppRunning(app) else {
            return
        }
        guard frontmostRefreshApp != app || frontmostRefreshTask == nil else {
            return
        }

        stopFrontmostRefresh()
        frontmostRefreshApp = app

        DebugLog.debug(
            "Starting frontmost refresh loop",
            metadata: ["app": app.rawValue, "reason": reason]
        )

        frontmostRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let interval = self.frontmostRefreshInterval()
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }

                guard await self.canCaptureState() else {
                    break
                }

                guard self.isAppFrontmost(app), self.isAppRunning(app) else {
                    break
                }

                await self.captureAppState(app: app, source: "frontmost-refresh")
            }

            self.clearFrontmostRefreshStateIfNeeded(for: app)
        }
    }

    private func stopFrontmostRefreshIfNeeded(for app: OfficeApp) {
        guard frontmostRefreshApp == app else {
            return
        }
        stopFrontmostRefresh()
    }

    private func stopFrontmostRefresh() {
        if let app = frontmostRefreshApp {
            DebugLog.debug("Stopping frontmost refresh loop", metadata: ["app": app.rawValue])
        }
        frontmostRefreshTask?.cancel()
        frontmostRefreshTask = nil
        frontmostRefreshApp = nil
    }

    private func clearFrontmostRefreshStateIfNeeded(for app: OfficeApp) {
        guard frontmostRefreshApp == app else {
            return
        }
        frontmostRefreshTask = nil
        frontmostRefreshApp = nil
    }

    private func frontmostRefreshInterval() -> UInt64 {
        switch PowerSourceKind.current() {
        case .powerAdapter:
            return powerAdapterRefreshNanoseconds
        case .battery:
            return batteryRefreshNanoseconds
        }
    }

    private func supportedCaptureApps() -> [OfficeApp] {
        OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps
    }

    private func isAppFrontmost(_ app: OfficeApp) -> Bool {
        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            return false
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private func isAppRunning(_ app: OfficeApp) -> Bool {
        runningApplication(for: app) != nil
    }

    private func runningApplication(for app: OfficeApp) -> NSRunningApplication? {
        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func frontmostSupportedApp() -> OfficeApp? {
        OfficeBundleRegistry.app(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            .flatMap { supportedCaptureApps().contains($0) ? $0 : nil }
    }

    private func publishStatus() {
        DaemonSharedIPC.publishStatus(stateStore.currentStatus())
    }
}

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var host: DaemonListenerHost?
    private var monitor: OfficeLifecycleMonitor?
    private var controller: HelperDaemonController?
    private var commandObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            ProcessInfo.processInfo.disableAutomaticTermination("Office Resume Helper monitoring")
            ProcessInfo.processInfo.disableSuddenTermination()

            let controller = try HelperDaemonController()
            self.controller = controller
            controller.start()
            startCommandObservers(controller: controller)

            let service = OfficeResumeDaemonService(handlers: controller.makeXPCHandlers())
            let host = DaemonListenerHost(service: service)
            host.resume()
            self.host = host

            let monitor = OfficeLifecycleMonitor(
                appCallback: { [weak controller] app, type, runningApplication in
                    Task { @MainActor in
                        controller?.handleLifecycleEvent(app: app, type: type, runningApplication: runningApplication)
                    }
                },
                sessionDidResignActiveCallback: { [weak controller] in
                    Task { @MainActor in
                        controller?.handleSessionDidResignActive()
                    }
                }
            )
            monitor.start()
            self.monitor = monitor
            DebugLog.info("OfficeResumeHelper app finished launching")
        } catch {
            DebugLog.error("OfficeResumeHelper failed to start", metadata: ["error": error.localizedDescription])
            NSLog("OfficeResumeHelper failed to start: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        stopCommandObservers()
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("Office Resume Helper monitoring")
        Task { @MainActor in
            controller?.stop()
        }
    }

    private func startCommandObservers(controller: HelperDaemonController) {
        let center = DistributedNotificationCenter.default()

        let pauseObserver = center.addObserver(
            forName: DaemonSharedIPC.pauseCommandName,
            object: nil,
            queue: nil
        ) { notification in
            let paused = (notification.userInfo?[DaemonSharedIPC.pausedUserInfoKey] as? Bool) ?? false
            Task { @MainActor in
                await controller.handleCommandSetPaused(paused)
            }
        }

        let restoreObserver = center.addObserver(
            forName: DaemonSharedIPC.restoreCommandName,
            object: nil,
            queue: nil
        ) { notification in
            let appRaw = notification.userInfo?[DaemonSharedIPC.appUserInfoKey] as? String
            Task { @MainActor in
                await controller.handleCommandRestoreNow(appRaw: appRaw)
            }
        }

        let clearObserver = center.addObserver(
            forName: DaemonSharedIPC.clearSnapshotCommandName,
            object: nil,
            queue: nil
        ) { notification in
            let appRaw = notification.userInfo?[DaemonSharedIPC.appUserInfoKey] as? String
            Task { @MainActor in
                await controller.handleCommandClearSnapshot(appRaw: appRaw)
            }
        }

        let refreshEntitlementObserver = center.addObserver(
            forName: DaemonSharedIPC.refreshEntitlementCommandName,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                await controller.handleCommandRefreshEntitlement()
            }
        }

        let quitHelperObserver = center.addObserver(
            forName: DaemonSharedIPC.quitHelperCommandName,
            object: nil,
            queue: nil
        ) { _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        commandObservers = [
            pauseObserver,
            restoreObserver,
            clearObserver,
            refreshEntitlementObserver,
            quitHelperObserver,
        ]
    }

    private func stopCommandObservers() {
        guard !commandObservers.isEmpty else {
            return
        }

        let center = DistributedNotificationCenter.default()
        for observer in commandObservers {
            center.removeObserver(observer)
        }
        commandObservers.removeAll()
    }
}
