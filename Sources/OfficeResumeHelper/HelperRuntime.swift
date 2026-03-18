import AppKit
import Foundation
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

@MainActor
final class HelperDaemonController {
    private enum DefaultsKey {
        static let isPaused = "com.pragprod.msofficeresume.isPaused"
    }

    private enum AppMailboxItem {
        case lifecycle(type: LifecycleEventType, runningApplication: NSRunningApplication?)
        case capture(source: String)
        case restore(
            source: String,
            runningApplication: NSRunningApplication?,
            continuation: CheckedContinuation<RestoreCommandResultDTO, Never>
        )
    }

    private let stateStore: DaemonStateStore
    private let snapshotStore: SnapshotStore
    private let folderAccessStore: FolderAccessStore
    private let restoreEngine: RestoreEngine
    private let entitlementProvider: EntitlementProvider
    private let adapters: [OfficeApp: OfficeAdapter]
    private let userDefaults: UserDefaults
    private lazy var axObserverManager = AccessibilityObserverManager { [weak self] app, notification, pid in
        Task { @MainActor in
            self?.handleAXNotification(app: app, notification: notification, pid: pid)
        }
    }

    private var isPaused: Bool
    private var observedLaunchIDs: [OfficeApp: String] = [:]
    private var observedLaunchFirstSeenAt: [OfficeApp: Date] = [:]
    private var pendingCaptureTasks: [OfficeApp: Task<Void, Never>] = [:]
    private var warmupCaptureTasks: [OfficeApp: Task<Void, Never>] = [:]
    private var captureInFlightApps: Set<OfficeApp> = []
    private var captureBackoffUntil: [OfficeApp: Date] = [:]
    private var appMailboxQueues: [OfficeApp: [AppMailboxItem]] = [:]
    private var appMailboxRunning: Set<OfficeApp> = []
    private var lastScriptingInteractionAt: [OfficeApp: Date] = [:]
    private var lastSuccessfulAXCaptureAt: [OfficeApp: Date] = [:]
    private var safetySweepTask: Task<Void, Never>?
    private var safetySweepApp: OfficeApp?

    private let deactivateCaptureDebounceNanoseconds: UInt64 = 350_000_000
    private let axCaptureDebounceNanoseconds: UInt64 = 250_000_000
    private let warmupCaptureIntervalNanoseconds: UInt64 = 1_000_000_000
    private let warmupCaptureAttempts: Int = 5
    private let safetySweepIntervalNanoseconds: UInt64 = 30_000_000_000
    private let safetySweepRecentAXWindow: TimeInterval = 30
    private let emptySnapshotProtectionWindow: TimeInterval = 60
    private let captureFailureBackoff: TimeInterval = 10
    private let lifecycleCaptureCooldown: TimeInterval = 2

    init(
        channel: StorageChannel? = nil,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaults()
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
            await refreshAccessibilityState(reason: "startup")
            await syncSnapshotTimestamps()
            await reconcileFrontmostAppAtStartup()
        }
    }

    func stop() {
        DebugLog.info("Helper daemon stopping")
        axObserverManager.detachAll()
        cancelPendingCaptures()
        stopSafetySweep()
        stateStore.setHelperRunning(false)
        publishStatus()
    }

    func makeXPCHandlers() -> DaemonServiceHandlers {
        DaemonServiceHandlers(
            getStatus: { [weak self] in
                if let self {
                    await self.refreshAccessibilityState(reason: "status-request")
                    return self.status()
                }
                return DaemonStatusDTO(
                    isPaused: true,
                    helperRunning: false,
                    accessibilityTrusted: false,
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
            },
            openAccessibilitySettings: { [weak self] in
                await self?.openAccessibilitySettings() ?? false
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

            switch type {
            case .appLaunched, .appActivated, .appTerminated:
                await refreshAccessibilityState(reason: "lifecycle-\(type.rawValue)")
            default:
                break
            }

            guard app != .onenote else {
                if type == .appTerminated || type == .appDeactivated {
                    stopSafetySweepIfNeeded(for: app)
                }
                return
            }
            enqueueLifecycleWork(app: app, type: type, runningApplication: runningApplication)
        }
    }

    func handleSessionDidResignActive() {
        Task { @MainActor in
            stopSafetySweep()
            guard await canCaptureState() else {
                return
            }

            for app in supportedCaptureApps() {
                guard isAppRunning(app) else {
                    continue
                }
                enqueueCaptureWork(app: app, source: "session")
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

    func handleCommandOpenAccessibilitySettings() async {
        _ = await openAccessibilitySettings()
    }

    private func status() -> DaemonStatusDTO {
        stateStore.currentStatus()
    }

    private func setPaused(_ paused: Bool) async -> Bool {
        isPaused = paused
        userDefaults.set(paused, forKey: DefaultsKey.isPaused)
        if paused {
            cancelPendingCaptures()
            stopSafetySweep()
        }
        let ok = stateStore.setPaused(paused)
        publishStatus()
        if !paused {
            await startSafetySweepForCurrentFrontmostApp(reason: "resume")
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
            let result = await enqueueRestoreWork(app: app, source: "manual")
            startWarmupCaptureIfNeeded(for: app, source: "restore-warmup")
            await startSafetySweepIfNeeded(for: app, reason: "manual-restore")
            return result
        }

        var restoredCount = 0
        var failedCount = 0

        for app in OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps {
            let result = await enqueueRestoreWork(app: app, source: "manual")
            restoredCount += result.restoredCount
            failedCount += result.failedCount
            startWarmupCaptureIfNeeded(for: app, source: "restore-warmup")
        }

        await startSafetySweepForCurrentFrontmostApp(reason: "manual-restore")

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

    private func processLifecycleEvent(
        app: OfficeApp,
        type: LifecycleEventType,
        runningApplication: NSRunningApplication?
    ) async {
        switch type {
        case .appLaunched:
            pendingCaptureTasks[app]?.cancel()
            pendingCaptureTasks.removeValue(forKey: app)

            let didAttemptRestore = await restoreAfterLaunchIfNeeded(app: app, runningApplication: runningApplication)
            guard await canCaptureState() else {
                return
            }
            if !didAttemptRestore {
                await captureAppState(app: app, source: "launch")
            }
            startWarmupCaptureIfNeeded(for: app, source: "launch-warmup")
            await startSafetySweepIfNeeded(for: app, reason: "launch")
        case .appActivated:
            pendingCaptureTasks[app]?.cancel()
            pendingCaptureTasks.removeValue(forKey: app)

            if shouldSuppressLifecycleCapture(for: app, type: type) {
                await startSafetySweepIfNeeded(for: app, reason: "activate-cooldown")
                return
            }
            guard await canCaptureState() else {
                return
            }
            await captureAppState(app: app, source: "activate")
            await startSafetySweepIfNeeded(for: app, reason: "activate")
        case .appDeactivated:
            stopSafetySweepIfNeeded(for: app)
            if shouldSuppressLifecycleCapture(for: app, type: type) {
                return
            }
            guard await canCaptureState() else {
                return
            }
            scheduleCapture(app: app, source: "deactivate", after: deactivateCaptureDebounceNanoseconds)
        case .appTerminated:
            stopSafetySweepIfNeeded(for: app)
            stopWarmupCaptureIfNeeded(for: app)
            pendingCaptureTasks[app]?.cancel()
            pendingCaptureTasks.removeValue(forKey: app)
            lastSuccessfulAXCaptureAt.removeValue(forKey: app)
        case .stateCaptured, .restoreStarted, .restoreSucceeded, .restoreFailed:
            break
        }
    }

    private func restoreAfterLaunchIfNeeded(app: OfficeApp, runningApplication: NSRunningApplication?) async -> Bool {
        await refreshEntitlementStatus()

        guard !isPaused else {
            return false
        }

        guard await entitlementProvider.canRestore() else {
            return false
        }

        guard OfficeBundleRegistry.automaticRestoreApps.contains(app) else {
            DebugLog.debug(
                "Automatic restore skipped for lifecycle-only app",
                metadata: ["app": app.rawValue]
            )
            return false
        }

        _ = await performRestore(app: app, source: "relaunch", runningApplication: runningApplication)
        startWarmupCaptureIfNeeded(for: app, source: "restore-warmup")
        await startSafetySweepIfNeeded(for: app, reason: "relaunch")
        return true
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
                noteScriptingInteraction(for: app)
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

        if let blockedUntil = captureBackoffUntil[app], blockedUntil > Date() {
            DebugLog.debug(
                "Skipped capture during backoff window",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                ]
            )
            return
        }

        guard captureInFlightApps.insert(app).inserted else {
            DebugLog.debug(
                "Skipped overlapping capture",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                ]
            )
            return
        }
        defer { captureInFlightApps.remove(app) }

        guard let adapter = adapters[app], app != .onenote else {
            return
        }

        do {
            noteScriptingInteraction(for: app)
            var snapshot = try await adapter.fetchState()
            captureBackoffUntil[app] = nil

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

            if source != "safety-sweep" || !snapshot.documents.isEmpty || !snapshot.windowsMeta.isEmpty {
                DebugLog.debug(
                    "Fetched app state",
                    metadata: [
                        "app": app.rawValue,
                        "source": source,
                        "documents": "\(snapshot.documents.count)",
                        "windows": "\(snapshot.windowsMeta.count)",
                    ]
                )
            }

            if source == "ax" {
                lastSuccessfulAXCaptureAt[app] = Date()
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
            captureBackoffUntil[app] = Date().addingTimeInterval(captureFailureBackoff)
            stopWarmupCaptureIfNeeded(for: app)
            stopSafetySweepIfNeeded(for: app)
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

    private func reconcileFrontmostAppAtStartup() async {
        guard let app = frontmostSupportedApp(),
              let runningApplication = runningApplication(for: app)
        else {
            return
        }

        DebugLog.debug(
            "Reconciling frontmost app at startup",
            metadata: ["app": app.rawValue]
        )

        let didAttemptRestore: Bool
        if !isPaused, await entitlementProvider.canRestore() {
            _ = await performRestore(app: app, source: "startup", runningApplication: runningApplication)
            didAttemptRestore = true
        } else {
            didAttemptRestore = false
        }

        guard await canCaptureState() else {
            return
        }

        if !didAttemptRestore {
            enqueueCaptureWork(app: app, source: "startup")
        }

        if captureBackoffUntil[app] == nil {
            await startSafetySweepIfNeeded(for: app, reason: "startup")
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
                stopSafetySweep()
            } else if !isPaused {
                await startSafetySweepForCurrentFrontmostApp(reason: "entitlement-refresh")
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
                stopSafetySweep()
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

    private func refreshAccessibilityState(reason: String) async {
        let trusted = axObserverManager.isTrusted()
        stateStore.setAccessibilityTrusted(trusted)

        if trusted {
            axObserverManager.syncObservedApplications()
        } else {
            axObserverManager.detachAll()
            cancelPendingCaptures()
            stopSafetySweep()
        }

        publishStatus()
        DebugLog.debug(
            "Accessibility trust refreshed",
            metadata: [
                "reason": reason,
                "trusted": trusted ? "true" : "false",
            ]
        )
    }

    private func handleAXNotification(app: OfficeApp, notification: String, pid: pid_t) {
        DebugLog.debug(
            "AX notification received",
            metadata: [
                "app": app.rawValue,
                "notification": notification,
                "pid": "\(pid)",
            ]
        )

        Task { @MainActor in
            guard await canCaptureState() else {
                return
            }
            scheduleCapture(app: app, source: "ax", after: axCaptureDebounceNanoseconds)
        }
    }

    private func openAccessibilitySettings() async -> Bool {
        let urls: [String] = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]

        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return true
            }
        }

        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
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

        if source == "activate" || source == "safety-sweep" {
            DebugLog.debug(
                "Skipped transient empty snapshot overwrite",
                metadata: [
                    "app": app.rawValue,
                    "source": source,
                    "launchID": newSnapshot.launchInstanceID,
                ]
            )
            return true
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

        guard stateStore.currentStatus().accessibilityTrusted else {
            return false
        }

        return await entitlementProvider.canMonitor()
    }

    private func cancelPendingCaptures() {
        for task in pendingCaptureTasks.values {
            task.cancel()
        }
        pendingCaptureTasks.removeAll()

        for task in warmupCaptureTasks.values {
            task.cancel()
        }
        warmupCaptureTasks.removeAll()
    }

    private func enqueueLifecycleWork(
        app: OfficeApp,
        type: LifecycleEventType,
        runningApplication: NSRunningApplication?
    ) {
        var queue = appMailboxQueues[app] ?? []
        let item = AppMailboxItem.lifecycle(type: type, runningApplication: runningApplication)

        switch type {
        case .appActivated, .appDeactivated:
            if let index = queue.lastIndex(where: { queued in
                if case let .lifecycle(existingType, _) = queued {
                    return existingType == .appActivated || existingType == .appDeactivated
                }
                return false
            }) {
                queue[index] = item
            } else {
                queue.append(item)
            }
        case .appTerminated:
            queue.removeAll { queued in
                switch queued {
                case .capture:
                    return true
                case let .lifecycle(existingType, _):
                    return existingType == .appActivated || existingType == .appDeactivated
                case .restore:
                    return false
                }
            }
            queue.append(item)
        default:
            queue.append(item)
        }

        appMailboxQueues[app] = queue
        processMailboxIfNeeded(for: app)
    }

    private func enqueueCaptureWork(app: OfficeApp, source: String) {
        var queue = appMailboxQueues[app] ?? []

        if let index = queue.firstIndex(where: { queued in
            if case .capture = queued {
                return true
            }
            return false
        }) {
            queue[index] = .capture(source: mergedCaptureSource(existingQueueItem: queue[index], newSource: source))
        } else {
            queue.append(.capture(source: source))
        }

        appMailboxQueues[app] = queue
        processMailboxIfNeeded(for: app)
    }

    private func enqueueRestoreWork(
        app: OfficeApp,
        source: String,
        runningApplication: NSRunningApplication? = nil
    ) async -> RestoreCommandResultDTO {
        await withCheckedContinuation { continuation in
            var queue = appMailboxQueues[app] ?? []
            queue.append(
                .restore(
                    source: source,
                    runningApplication: runningApplication,
                    continuation: continuation
                )
            )
            appMailboxQueues[app] = queue
            processMailboxIfNeeded(for: app)
        }
    }

    private func processMailboxIfNeeded(for app: OfficeApp) {
        guard !appMailboxRunning.contains(app) else {
            return
        }
        guard !(appMailboxQueues[app]?.isEmpty ?? true) else {
            return
        }

        appMailboxRunning.insert(app)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while let item = self.dequeueMailboxItem(for: app) {
                await self.processMailboxItem(item, for: app)
            }

            self.appMailboxRunning.remove(app)
            if !(self.appMailboxQueues[app]?.isEmpty ?? true) {
                self.processMailboxIfNeeded(for: app)
            }
        }
    }

    private func dequeueMailboxItem(for app: OfficeApp) -> AppMailboxItem? {
        guard var queue = appMailboxQueues[app], !queue.isEmpty else {
            appMailboxQueues.removeValue(forKey: app)
            return nil
        }

        let item = queue.removeFirst()
        if queue.isEmpty {
            appMailboxQueues.removeValue(forKey: app)
        } else {
            appMailboxQueues[app] = queue
        }
        return item
    }

    private func processMailboxItem(_ item: AppMailboxItem, for app: OfficeApp) async {
        switch item {
        case let .lifecycle(type, runningApplication):
            await processLifecycleEvent(app: app, type: type, runningApplication: runningApplication)
        case let .capture(source):
            guard await canCaptureState() else {
                return
            }
            await captureAppState(app: app, source: source)
        case let .restore(source, runningApplication, continuation):
            let result = await performRestore(app: app, source: source, runningApplication: runningApplication)
            continuation.resume(returning: result)
        }
    }

    private func mergedCaptureSource(existingQueueItem: AppMailboxItem, newSource: String) -> String {
        guard case let .capture(existingSource) = existingQueueItem else {
            return newSource
        }

        if existingSource == "ax" || newSource == "ax" {
            return "ax"
        }
        if newSource == "deactivate" {
            return newSource
        }
        return existingSource
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

            self.enqueueCaptureWork(app: app, source: source)
        }

        pendingCaptureTasks[app] = task
    }

    private func startWarmupCaptureIfNeeded(for app: OfficeApp, source: String) {
        guard OfficeBundleRegistry.documentRestoreApps.contains(app) else {
            return
        }
        guard !isAppFrontmost(app) else {
            return
        }

        warmupCaptureTasks[app]?.cancel()

        DebugLog.debug(
            "Starting warm-up capture window",
            metadata: [
                "app": app.rawValue,
                "source": source,
                "attempts": "\(warmupCaptureAttempts)",
            ]
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer { self.clearWarmupCaptureTaskIfNeeded(for: app) }

            for _ in 0..<self.warmupCaptureAttempts {
                do {
                    try await Task.sleep(nanoseconds: self.warmupCaptureIntervalNanoseconds)
                } catch {
                    return
                }

                guard self.isAppRunning(app) else {
                    return
                }

                guard await self.canCaptureState() else {
                    return
                }

                self.enqueueCaptureWork(app: app, source: source)
            }
        }

        warmupCaptureTasks[app] = task
    }

    private func stopWarmupCaptureIfNeeded(for app: OfficeApp) {
        guard warmupCaptureTasks[app] != nil else {
            return
        }
        DebugLog.debug("Stopping warm-up capture window", metadata: ["app": app.rawValue])
        warmupCaptureTasks[app]?.cancel()
        warmupCaptureTasks.removeValue(forKey: app)
    }

    private func clearWarmupCaptureTaskIfNeeded(for app: OfficeApp) {
        warmupCaptureTasks[app] = nil
    }

    private func noteScriptingInteraction(for app: OfficeApp) {
        lastScriptingInteractionAt[app] = Date()
    }

    private func shouldSuppressLifecycleCapture(for app: OfficeApp, type: LifecycleEventType) -> Bool {
        guard type == .appActivated || type == .appDeactivated else {
            return false
        }
        guard let lastInteraction = lastScriptingInteractionAt[app] else {
            return false
        }

        let age = Date().timeIntervalSince(lastInteraction)
        guard age < lifecycleCaptureCooldown else {
            return false
        }

        DebugLog.debug(
            "Suppressed lifecycle capture during scripting cooldown",
            metadata: [
                "app": app.rawValue,
                "event": type.rawValue,
                "ageSeconds": String(format: "%.2f", age),
            ]
        )
        return true
    }

    private func startSafetySweepForCurrentFrontmostApp(reason: String) async {
        guard let app = frontmostSupportedApp() else {
            stopSafetySweep()
            return
        }

        await startSafetySweepIfNeeded(for: app, reason: reason)
    }

    private func startSafetySweepIfNeeded(for app: OfficeApp, reason: String) async {
        guard supportedCaptureApps().contains(app) else {
            return
        }
        guard await canCaptureState() else {
            return
        }
        guard isAppFrontmost(app), isAppRunning(app) else {
            return
        }
        guard safetySweepApp != app || safetySweepTask == nil else {
            return
        }

        stopSafetySweep()
        safetySweepApp = app

        DebugLog.debug(
            "Starting sparse safety sweep",
            metadata: ["app": app.rawValue, "reason": reason]
        )

        safetySweepTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.safetySweepIntervalNanoseconds)
                } catch {
                    break
                }

                guard await self.canCaptureState() else {
                    break
                }

                guard self.isAppFrontmost(app), self.isAppRunning(app) else {
                    break
                }

                if let lastAXCaptureAt = self.lastSuccessfulAXCaptureAt[app],
                   Date().timeIntervalSince(lastAXCaptureAt) < self.safetySweepRecentAXWindow {
                    continue
                }

                self.enqueueCaptureWork(app: app, source: "safety-sweep")
            }

            self.clearSafetySweepStateIfNeeded(for: app)
        }
    }

    private func stopSafetySweepIfNeeded(for app: OfficeApp) {
        guard safetySweepApp == app else {
            return
        }
        stopSafetySweep()
    }

    private func stopSafetySweep() {
        if let app = safetySweepApp {
            DebugLog.debug("Stopping sparse safety sweep", metadata: ["app": app.rawValue])
        }
        safetySweepTask?.cancel()
        safetySweepTask = nil
        safetySweepApp = nil
    }

    private func clearSafetySweepStateIfNeeded(for app: OfficeApp) {
        guard safetySweepApp == app else {
            return
        }
        safetySweepTask = nil
        safetySweepApp = nil
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

        let openAccessibilityObserver = center.addObserver(
            forName: DaemonSharedIPC.openAccessibilitySettingsCommandName,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                await controller.handleCommandOpenAccessibilitySettings()
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
            openAccessibilityObserver,
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
