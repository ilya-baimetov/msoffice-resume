import AppKit
import Foundation
import OfficeResumeCore

final class OfficeLifecycleMonitor {
    private var observers: [NSObjectProtocol] = []
    private let callback: (OfficeApp, LifecycleEventType, NSRunningApplication?) -> Void

    init(callback: @escaping (OfficeApp, LifecycleEventType, NSRunningApplication?) -> Void) {
        self.callback = callback
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

        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handle(notification: notification, type: .appTerminated)
        }

        observers = [launched, terminated]
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

        callback(mapped, type, runningApp)
    }
}

@MainActor
final class HelperDaemonController {
    private enum DefaultsKey {
        static let pollingInterval = "com.pragprod.msofficeresume.pollingInterval"
        static let isPaused = "com.pragprod.msofficeresume.isPaused"
    }

    private let stateStore: DaemonStateStore
    private let snapshotStore: SnapshotStore
    private let restoreEngine: RestoreEngine
    private let entitlementProvider: EntitlementProvider
    private let adapters: [OfficeApp: OfficeAdapter]
    private let userDefaults: UserDefaults

    private var pollingTimer: Timer?
    private var pollingInterval: PollingInterval
    private var isPaused: Bool

    init(channel: StorageChannel? = nil, userDefaults: UserDefaults = .standard) throws {
        let stateStore = DaemonStateStore()
        let resolvedChannel = channel ?? Self.defaultStorageChannel()
        let snapshotStore = FileSnapshotStore(channel: resolvedChannel)
        let markerStore = try FileRestoreMarkerStore()
        let entitlementStore = try EntitlementFileStore()

        self.stateStore = stateStore
        self.snapshotStore = snapshotStore
        self.restoreEngine = RestoreEngine(snapshotStore: snapshotStore, markerStore: markerStore)
        self.entitlementProvider = TrialEntitlementProvider(store: entitlementStore)
        self.adapters = OfficeAdapterFactory.makeDefaultAdapters(snapshotStore: snapshotStore)
        self.userDefaults = userDefaults

        if let raw = userDefaults.string(forKey: DefaultsKey.pollingInterval),
           let persisted = PollingInterval(rawValue: raw) {
            pollingInterval = persisted
        } else {
            pollingInterval = .fifteenSeconds
        }
        isPaused = userDefaults.bool(forKey: DefaultsKey.isPaused)

        _ = stateStore.setPollingInterval(pollingInterval)
        _ = stateStore.setPaused(isPaused)
        stateStore.setHelperRunning(true)
    }

    func start() {
        configurePollingTimer()

        Task {
            await refreshEntitlementStatus()
            await syncSnapshotTimestamps()
            await pollRunningAppsIfNeeded(source: "startup")
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        stateStore.setHelperRunning(false)
    }

    func makeXPCHandlers() -> DaemonServiceHandlers {
        DaemonServiceHandlers(
            getStatus: { [weak self] in
                await self?.status() ?? DaemonStatusDTO(
                    isPaused: true,
                    pollingInterval: .none,
                    helperRunning: false,
                    entitlementActive: false,
                    latestSnapshotCapturedAt: [:],
                    unsupportedApps: OfficeBundleRegistry.unsupportedApps
                )
            },
            setPollingInterval: { [weak self] interval in
                await self?.setPollingInterval(interval) ?? false
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
            recentEvents: { [weak self] limit in
                await self?.recentEvents(limit: limit) ?? []
            }
        )
    }

    func handleLifecycleEvent(app: OfficeApp, type: LifecycleEventType, runningApplication: NSRunningApplication?) {
        let details = lifecycleDetails(type: type, runningApplication: runningApplication)
        stateStore.recordEvent(app: app, type: type, details: details)

        Task {
            let event = LifecycleEvent(app: app, type: type, timestamp: Date(), details: details)
            try? await snapshotStore.appendEvent(event)

            if type == .appLaunched {
                await restoreAfterLaunchIfNeeded(app: app, runningApplication: runningApplication)
            }
        }
    }

    private func status() -> DaemonStatusDTO {
        stateStore.currentStatus()
    }

    private func setPollingInterval(_ interval: PollingInterval) async -> Bool {
        pollingInterval = interval
        userDefaults.set(interval.rawValue, forKey: DefaultsKey.pollingInterval)
        let ok = stateStore.setPollingInterval(interval)
        configurePollingTimer()
        return ok
    }

    private func setPaused(_ paused: Bool) async -> Bool {
        isPaused = paused
        userDefaults.set(paused, forKey: DefaultsKey.isPaused)
        let ok = stateStore.setPaused(paused)
        configurePollingTimer()
        return ok
    }

    private func restoreNow(app: OfficeApp?) async -> RestoreCommandResultDTO {
        await refreshEntitlementStatus()

        guard await entitlementProvider.canRestore() else {
            return RestoreCommandResultDTO(succeeded: false, restoredCount: 0, failedCount: 0)
        }

        if let app {
            return await performRestore(app: app, source: "manual")
        }

        var restoredCount = 0
        var failedCount = 0

        for app in OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps {
            let result = await performRestore(app: app, source: "manual")
            restoredCount += result.restoredCount
            failedCount += result.failedCount
        }

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

    private func recentEvents(limit: Int) -> [LifecycleEventDTO] {
        stateStore.recentEvents(limit: limit)
    }

    private func restoreAfterLaunchIfNeeded(app: OfficeApp, runningApplication: NSRunningApplication?) async {
        await refreshEntitlementStatus()

        guard !isPaused else {
            return
        }

        guard await entitlementProvider.canRestore() else {
            return
        }

        _ = await performRestore(app: app, source: "relaunch", runningApplication: runningApplication)
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
                return RestoreCommandResultDTO(succeeded: true, restoredCount: 0, failedCount: 0)
            }

            stateStore.recordEvent(app: app, type: .restoreStarted, details: ["source": source, "launch": launchID])
            try await snapshotStore.appendEvent(
                LifecycleEvent(app: app, type: .restoreStarted, timestamp: Date(), details: ["source": source, "launch": launchID])
            )

            let restoreSnapshot = AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: Date(),
                documents: plan.documentsToOpen,
                windowsMeta: [],
                restoreAttemptedForLaunch: false
            )

            let restoreResult = try await adapter.restore(snapshot: restoreSnapshot)
            try await restoreEngine.markRestoreCompleted(app: app, launchInstanceID: launchID)

            if restoreResult.failedPaths.isEmpty {
                stateStore.recordEvent(
                    app: app,
                    type: .restoreSucceeded,
                    details: ["source": source, "restored": "\(restoreResult.restoredPaths.count)"]
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
                stateStore.recordEvent(
                    app: app,
                    type: .restoreFailed,
                    details: [
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
            stateStore.recordEvent(app: app, type: .restoreFailed, details: ["source": source, "error": error.localizedDescription])
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

    private func configurePollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil

        guard !isPaused else {
            return
        }

        guard let seconds = pollingInterval.seconds else {
            return
        }

        pollingTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.pollRunningAppsIfNeeded(source: "timer")
            }
        }
    }

    private func pollRunningAppsIfNeeded(source: String) async {
        await refreshEntitlementStatus()

        guard !isPaused else {
            return
        }

        guard await entitlementProvider.canMonitor() else {
            return
        }

        for app in OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps {
            guard isAppRunning(app: app) else {
                continue
            }
            await captureAppState(app: app, source: source)
        }
    }

    private func captureAppState(app: OfficeApp, source: String) async {
        guard let adapter = adapters[app] else {
            return
        }

        do {
            var snapshot = try await adapter.fetchState()

            if OfficeBundleRegistry.documentRestoreApps.contains(app) {
                let artifacts = try await adapter.forceSaveUntitled(state: snapshot)
                if !artifacts.isEmpty {
                    let persistedDocs = snapshot.documents.filter { $0.isSaved && !$0.canonicalPath.isEmpty }
                    snapshot = AppSnapshot(
                        app: snapshot.app,
                        launchInstanceID: snapshot.launchInstanceID,
                        capturedAt: snapshot.capturedAt,
                        documents: dedupeDocuments(persistedDocs + artifacts),
                        windowsMeta: snapshot.windowsMeta,
                        restoreAttemptedForLaunch: snapshot.restoreAttemptedForLaunch
                    )
                }
            }

            let current = try await snapshotStore.loadSnapshot(for: app)
            if shouldPersist(newSnapshot: snapshot, currentSnapshot: current) {
                try await snapshotStore.saveSnapshot(snapshot)
                stateStore.updateLatestSnapshot(app: app, capturedAt: snapshot.capturedAt)
            }

            if OfficeBundleRegistry.documentRestoreApps.contains(app) {
                let referenced = Set(snapshot.documents.map(\.canonicalPath))
                try await snapshotStore.purgeUnreferencedArtifacts(for: app, referencedPaths: referenced)
            }

            let details = ["source": source, "documents": "\(snapshot.documents.count)"]
            stateStore.recordEvent(app: app, type: .statePolled, details: details)
            try await snapshotStore.appendEvent(LifecycleEvent(app: app, type: .statePolled, timestamp: Date(), details: details))
        } catch {
            stateStore.recordEvent(app: app, type: .statePolled, details: ["source": source, "error": error.localizedDescription])
            try? await snapshotStore.appendEvent(
                LifecycleEvent(
                    app: app,
                    type: .statePolled,
                    timestamp: Date(),
                    details: ["source": source, "error": error.localizedDescription]
                )
            )
        }
    }

    private func refreshEntitlementStatus() async {
        do {
            let state = try await entitlementProvider.refresh()
            stateStore.setEntitlementActive(state.isActive)
        } catch {
            let state = await entitlementProvider.currentState()
            stateStore.setEntitlementActive(state.isActive)
        }
    }

    private func syncSnapshotTimestamps() async {
        let timestamps = (try? await snapshotStore.latestSnapshotCapturedAt()) ?? [:]
        stateStore.setLatestSnapshots(timestamps)
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

    private func shouldPersist(newSnapshot: AppSnapshot, currentSnapshot: AppSnapshot?) -> Bool {
        guard let currentSnapshot else {
            return true
        }

        if currentSnapshot.documents != newSnapshot.documents {
            return true
        }

        return currentSnapshot.windowsMeta != newSnapshot.windowsMeta
    }

    private func dedupeDocuments(_ documents: [DocumentSnapshot]) -> [DocumentSnapshot] {
        var seen: Set<String> = []
        var output: [DocumentSnapshot] = []

        for doc in documents {
            guard !doc.canonicalPath.isEmpty else {
                continue
            }
            if seen.insert(doc.canonicalPath).inserted {
                output.append(doc)
            }
        }

        return output
    }

    private func isAppRunning(app: OfficeApp) -> Bool {
        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            return false
        }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func launchInstanceID(for app: OfficeApp, runningApplication: NSRunningApplication?) -> String {
        if let runningApplication {
            return makeLaunchID(for: runningApplication)
        }

        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            return "unknown"
        }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return makeLaunchID(for: app)
        }

        return "unknown"
    }

    private func makeLaunchID(for app: NSRunningApplication) -> String {
        let launchTimestamp = app.launchDate?.timeIntervalSince1970 ?? 0
        return "\(app.processIdentifier)-\(Int64(launchTimestamp))"
    }

    nonisolated private static func defaultStorageChannel() -> StorageChannel {
        let appGroupIdentifier = "group.com.pragprod.msofficeresume"
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil {
            return .mas(appGroupIdentifier: appGroupIdentifier)
        }
        return .direct
    }
}

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var host: DaemonListenerHost?
    private var monitor: OfficeLifecycleMonitor?
    private var controller: HelperDaemonController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let controller = try HelperDaemonController()
            self.controller = controller
            controller.start()

            let service = OfficeResumeDaemonService(handlers: controller.makeXPCHandlers())
            let host = DaemonListenerHost(service: service)
            try host.resume()
            self.host = host

            let monitor = OfficeLifecycleMonitor { [weak controller] app, type, runningApplication in
                Task { @MainActor in
                    controller?.handleLifecycleEvent(app: app, type: type, runningApplication: runningApplication)
                }
            }
            monitor.start()
            self.monitor = monitor
        } catch {
            NSLog("OfficeResumeHelper failed to start: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        Task { @MainActor in
            controller?.stop()
        }
    }
}
