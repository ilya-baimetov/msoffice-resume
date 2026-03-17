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

final class OfficeAccessibilityMonitor {
    typealias EventCallback = (OfficeApp, String, pid_t) -> Void

    private final class ObserverEntry {
        let app: OfficeApp
        let pid: pid_t
        let observer: AXObserver

        init(app: OfficeApp, pid: pid_t, observer: AXObserver) {
            self.app = app
            self.pid = pid
            self.observer = observer
        }
    }

    private var observersByPID: [pid_t: ObserverEntry] = [:]
    private var appByObserverID: [ObjectIdentifier: OfficeApp] = [:]
    private var pidByObserverID: [ObjectIdentifier: pid_t] = [:]
    private let callback: EventCallback
    private(set) var isTrusted = false

    init(callback: @escaping EventCallback) {
        self.callback = callback
    }

    @discardableResult
    func start(prompt: Bool = true) -> Bool {
        let trusted = refreshTrust(prompt: prompt)
        if !trusted {
            DebugLog.warning("Accessibility permission is not granted; event interception will be limited")
        }
        return trusted
    }

    @discardableResult
    func refreshTrust(prompt: Bool = false) -> Bool {
        let trusted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        isTrusted = trusted
        return trusted
    }

    func stop() {
        let pids = Array(observersByPID.keys)
        for pid in pids {
            detach(pid: pid)
        }
    }

    func attach(app: OfficeApp, runningApplication: NSRunningApplication?) {
        guard isTrusted else {
            return
        }
        guard let runningApplication else {
            return
        }

        let pid = runningApplication.processIdentifier
        guard observersByPID[pid] == nil else {
            return
        }

        var observerRef: AXObserver?
        let createResult = AXObserverCreate(pid, Self.observerCallback, &observerRef)
        guard createResult == .success, let observer = observerRef else {
            DebugLog.warning(
                "Failed to create AX observer",
                metadata: [
                    "app": app.rawValue,
                    "pid": "\(pid)",
                    "result": "\(createResult.rawValue)",
                ]
            )
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
        ]

        for notification in notifications {
            let addResult = AXObserverAddNotification(observer, appElement, notification, refcon)
            if addResult != .success && addResult != .notificationAlreadyRegistered {
                DebugLog.warning(
                    "Failed to register AX notification",
                    metadata: [
                        "app": app.rawValue,
                        "pid": "\(pid)",
                        "notification": notification as String,
                        "result": "\(addResult.rawValue)",
                    ]
                )
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observersByPID[pid] = ObserverEntry(app: app, pid: pid, observer: observer)
        appByObserverID[ObjectIdentifier(observer)] = app
        pidByObserverID[ObjectIdentifier(observer)] = pid
        DebugLog.debug("AX observer attached", metadata: ["app": app.rawValue, "pid": "\(pid)"])
    }

    func detach(runningApplication: NSRunningApplication?) {
        guard let runningApplication else {
            return
        }
        detach(pid: runningApplication.processIdentifier)
    }

    private func detach(pid: pid_t) {
        guard let entry = observersByPID.removeValue(forKey: pid) else {
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        appByObserverID.removeValue(forKey: ObjectIdentifier(entry.observer))
        pidByObserverID.removeValue(forKey: ObjectIdentifier(entry.observer))
        DebugLog.debug("AX observer detached", metadata: ["app": entry.app.rawValue, "pid": "\(pid)"])
    }

    private func handle(observer: AXObserver, notification: String) {
        let observerID = ObjectIdentifier(observer)
        guard
            let app = appByObserverID[observerID],
            let pid = pidByObserverID[observerID]
        else {
            return
        }
        callback(app, mapNotificationName(notification), pid)
    }

    private func mapNotificationName(_ notification: String) -> String {
        switch notification {
        case String(kAXWindowCreatedNotification):
            return "windowCreated"
        case String(kAXUIElementDestroyedNotification):
            return "windowDestroyed"
        case String(kAXFocusedWindowChangedNotification):
            return "focusedWindowChanged"
        case String(kAXTitleChangedNotification):
            return "windowTitleChanged"
        default:
            return notification
        }
    }

    private static let observerCallback: AXObserverCallback = { observer, _, notification, refcon in
        guard let refcon else {
            return
        }
        let monitor = Unmanaged<OfficeAccessibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(observer: observer, notification: notification as String)
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
    private var pendingAXCaptureTasks: [OfficeApp: Task<Void, Never>] = [:]
    private let accessibilityDebounceNanoseconds: UInt64 = 700_000_000
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

        Task {
            await refreshEntitlementStatus()
            await syncSnapshotTimestamps()
            await restoreRunningAppsAtStartup()
            await captureRunningAppsAtStartup()
        }
    }

    func stop() {
        DebugLog.info("Helper daemon stopping")
        for task in pendingAXCaptureTasks.values {
            task.cancel()
        }
        pendingAXCaptureTasks.removeAll()
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
                    accessibilityTrusted: false,
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

        Task {
            let event = LifecycleEvent(app: app, type: type, timestamp: Date(), details: details)
            try? await snapshotStore.appendEvent(event)

            if type == .appLaunched {
                await restoreAfterLaunchIfNeeded(app: app, runningApplication: runningApplication)
                guard await canCaptureState() else {
                    return
                }
                await captureAppState(app: app, source: "launch")
            }
        }
    }

    func setAccessibilityTrusted(_ trusted: Bool) {
        stateStore.setAccessibilityTrusted(trusted)
        publishStatus()
        DebugLog.info(
            "Accessibility permission state updated",
            metadata: ["trusted": trusted ? "true" : "false"]
        )
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

    func handleAccessibilityEvent(app: OfficeApp, event: String, pid: pid_t) {
        guard app != .onenote else {
            return
        }

        let source = "ax:\(event)"
        DebugLog.debug(
            "Accessibility event captured",
            metadata: ["app": app.rawValue, "event": event, "pid": "\(pid)"]
        )

        if let existing = pendingAXCaptureTasks[app] {
            existing.cancel()
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            guard await self.canCaptureState() else {
                return
            }
            do {
                try await Task.sleep(nanoseconds: self.accessibilityDebounceNanoseconds)
            } catch {
                return
            }
            guard await self.canCaptureState() else {
                return
            }
            await self.captureAppState(app: app, source: source)
        }
        pendingAXCaptureTasks[app] = task
    }

    private func status() -> DaemonStatusDTO {
        stateStore.currentStatus()
    }

    private func setPaused(_ paused: Bool) async -> Bool {
        isPaused = paused
        userDefaults.set(paused, forKey: DefaultsKey.isPaused)
        if paused {
            cancelPendingAccessibilityCaptures()
        }
        let ok = stateStore.setPaused(paused)
        publishStatus()
        DebugLog.info("Pause state updated", metadata: ["paused": paused ? "true" : "false", "ok": ok ? "true" : "false"])
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
        pendingAXCaptureTasks[app] = nil

        guard await canCaptureState() else {
            return
        }

        guard let adapter = adapters[app] else {
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

        for app in OfficeBundleRegistry.automaticRestoreApps {
            guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
                continue
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if !running.isEmpty {
                await captureAppState(app: app, source: "startup")
            }
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
            guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
                continue
            }

            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard let runningApplication = running.first else {
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
                cancelPendingAccessibilityCaptures()
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
                cancelPendingAccessibilityCaptures()
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

    private func canCaptureState() async -> Bool {
        guard !isPaused else {
            return false
        }

        return await entitlementProvider.canMonitor()
    }

    private func cancelPendingAccessibilityCaptures() {
        for task in pendingAXCaptureTasks.values {
            task.cancel()
        }
        pendingAXCaptureTasks.removeAll()
    }

    private func publishStatus() {
        DaemonSharedIPC.publishStatus(stateStore.currentStatus())
    }
}

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var host: DaemonListenerHost?
    private var monitor: OfficeLifecycleMonitor?
    private var accessibilityMonitor: OfficeAccessibilityMonitor?
    private var controller: HelperDaemonController?
    private var commandObservers: [NSObjectProtocol] = []
    private var accessibilityTrustTimer: Timer?
    private var lastAccessibilityTrusted: Bool?

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

            let accessibilityMonitor = OfficeAccessibilityMonitor { [weak controller] app, event, pid in
                Task { @MainActor in
                    controller?.handleAccessibilityEvent(app: app, event: event, pid: pid)
                }
            }
            let trusted = accessibilityMonitor.start(prompt: false)
            controller.setAccessibilityTrusted(trusted)
            lastAccessibilityTrusted = trusted
            self.accessibilityMonitor = accessibilityMonitor

            attachAccessibilityObserversForRunningApps(accessibilityMonitor: accessibilityMonitor)
            startAccessibilityTrustRefresh(accessibilityMonitor: accessibilityMonitor, controller: controller)

            let monitor = OfficeLifecycleMonitor { [weak controller, weak accessibilityMonitor] app, type, runningApplication in
                Task { @MainActor in
                    if let accessibilityMonitor {
                        let trustedNow = accessibilityMonitor.refreshTrust(prompt: false)
                        controller?.setAccessibilityTrusted(trustedNow)
                        if !trustedNow {
                            accessibilityMonitor.stop()
                        }
                    }
                    controller?.handleLifecycleEvent(app: app, type: type, runningApplication: runningApplication)
                    if type == .appLaunched {
                        accessibilityMonitor?.attach(app: app, runningApplication: runningApplication)
                    } else if type == .appTerminated {
                        accessibilityMonitor?.detach(runningApplication: runningApplication)
                    }
                }
            }
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
        accessibilityMonitor?.stop()
        stopAccessibilityTrustRefresh()
        stopCommandObservers()
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("Office Resume Helper monitoring")
        Task { @MainActor in
            controller?.stop()
        }
    }

    private func attachAccessibilityObserversForRunningApps(accessibilityMonitor: OfficeAccessibilityMonitor) {
        let appsToObserve = OfficeBundleRegistry.documentRestoreApps + OfficeBundleRegistry.lifecycleOnlyApps
        for app in appsToObserve {
            guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
                continue
            }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                accessibilityMonitor.attach(app: app, runningApplication: running)
            }
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

        let promptAccessibilityObserver = center.addObserver(
            forName: DaemonSharedIPC.promptAccessibilityCommandName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.promptAccessibilityPermission(controller: controller)
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
            promptAccessibilityObserver,
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

    @MainActor
    private func promptAccessibilityPermission(controller: HelperDaemonController) {
        let trustedNow: Bool
        if let accessibilityMonitor {
            trustedNow = accessibilityMonitor.refreshTrust(prompt: true)
            if trustedNow {
                attachAccessibilityObserversForRunningApps(accessibilityMonitor: accessibilityMonitor)
            } else {
                accessibilityMonitor.stop()
            }
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trustedNow = AXIsProcessTrustedWithOptions(options)
        }

        lastAccessibilityTrusted = trustedNow
        controller.setAccessibilityTrusted(trustedNow)
    }

    private func startAccessibilityTrustRefresh(
        accessibilityMonitor: OfficeAccessibilityMonitor,
        controller: HelperDaemonController
    ) {
        stopAccessibilityTrustRefresh()

        accessibilityTrustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak accessibilityMonitor] _ in
            guard
                let self,
                let accessibilityMonitor
            else {
                return
            }

            let trustedNow = accessibilityMonitor.refreshTrust(prompt: false)
            guard trustedNow != self.lastAccessibilityTrusted else {
                return
            }

            self.lastAccessibilityTrusted = trustedNow

            Task { @MainActor in
                controller.setAccessibilityTrusted(trustedNow)
            }

            if trustedNow {
                self.attachAccessibilityObserversForRunningApps(accessibilityMonitor: accessibilityMonitor)
            } else {
                accessibilityMonitor.stop()
            }
        }
    }

    private func stopAccessibilityTrustRefresh() {
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
    }
}
