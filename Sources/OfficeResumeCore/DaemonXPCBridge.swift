import Foundation

public enum DaemonXPCConstants {
    public static let machServiceName = "com.pragprod.msofficeresume.daemon"
}

public enum DaemonXPCError: Error, LocalizedError {
    case connectionFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Unable to connect to helper XPC service."
        case .decodingFailed:
            return "Unable to decode response payload."
        }
    }
}

@objc public protocol OfficeResumeDaemonXPCProtocol {
    func getStatus(reply: @escaping (NSData?) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (NSData?) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
    func recentEvents(_ limit: Int, reply: @escaping (NSData?) -> Void)
}

public final class DaemonStateStore {
    private let queue = DispatchQueue(label: "com.pragprod.msofficeresume.daemon-state")
    private var status = DaemonStatusDTO(
        isPaused: false,
        helperRunning: true,
        entitlementActive: true,
        entitlementPlan: .trial,
        entitlementValidUntil: nil,
        entitlementTrialEndsAt: nil,
        accessibilityTrusted: false,
        latestSnapshotCapturedAt: [:],
        unsupportedApps: OfficeBundleRegistry.unsupportedApps
    )
    private var events: [LifecycleEventDTO] = []

    public init() {}

    public func currentStatus() -> DaemonStatusDTO {
        queue.sync { status }
    }

    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: paused,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                entitlementPlan: status.entitlementPlan,
                entitlementValidUntil: status.entitlementValidUntil,
                entitlementTrialEndsAt: status.entitlementTrialEndsAt,
                accessibilityTrusted: status.accessibilityTrusted,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
            return true
        }
    }

    public func setHelperRunning(_ running: Bool) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                helperRunning: running,
                entitlementActive: status.entitlementActive,
                entitlementPlan: status.entitlementPlan,
                entitlementValidUntil: status.entitlementValidUntil,
                entitlementTrialEndsAt: status.entitlementTrialEndsAt,
                accessibilityTrusted: status.accessibilityTrusted,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func setEntitlementState(_ entitlement: EntitlementState) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                helperRunning: status.helperRunning,
                entitlementActive: entitlement.isActive,
                entitlementPlan: entitlement.plan,
                entitlementValidUntil: entitlement.validUntil,
                entitlementTrialEndsAt: entitlement.trialEndsAt,
                accessibilityTrusted: status.accessibilityTrusted,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func setAccessibilityTrusted(_ isTrusted: Bool) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                entitlementPlan: status.entitlementPlan,
                entitlementValidUntil: status.entitlementValidUntil,
                entitlementTrialEndsAt: status.entitlementTrialEndsAt,
                accessibilityTrusted: isTrusted,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func updateLatestSnapshot(app: OfficeApp, capturedAt: Date) {
        queue.sync {
            var updated = status.latestSnapshotCapturedAt
            updated[app] = capturedAt
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                entitlementPlan: status.entitlementPlan,
                entitlementValidUntil: status.entitlementValidUntil,
                entitlementTrialEndsAt: status.entitlementTrialEndsAt,
                accessibilityTrusted: status.accessibilityTrusted,
                latestSnapshotCapturedAt: updated,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func setLatestSnapshots(_ snapshots: [OfficeApp: Date]) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                entitlementPlan: status.entitlementPlan,
                entitlementValidUntil: status.entitlementValidUntil,
                entitlementTrialEndsAt: status.entitlementTrialEndsAt,
                accessibilityTrusted: status.accessibilityTrusted,
                latestSnapshotCapturedAt: snapshots,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func recordEvent(app: OfficeApp, type: LifecycleEventType, details: [String: String] = [:]) {
        queue.sync {
            events.append(LifecycleEventDTO(app: app, type: type, timestamp: Date(), details: details))
            if events.count > 500 {
                events.removeFirst(events.count - 500)
            }
        }
    }

    public func recentEvents(limit: Int) -> [LifecycleEventDTO] {
        queue.sync {
            let slice = events.suffix(max(0, limit))
            return Array(slice.reversed())
        }
    }
}

public struct DaemonServiceHandlers {
    public let getStatus: () async -> DaemonStatusDTO
    public let setPaused: (Bool) async -> Bool
    public let restoreNow: (OfficeApp?) async -> RestoreCommandResultDTO
    public let clearSnapshot: (OfficeApp?) async -> Bool
    public let recentEvents: (Int) async -> [LifecycleEventDTO]

    public init(
        getStatus: @escaping () async -> DaemonStatusDTO,
        setPaused: @escaping (Bool) async -> Bool,
        restoreNow: @escaping (OfficeApp?) async -> RestoreCommandResultDTO,
        clearSnapshot: @escaping (OfficeApp?) async -> Bool,
        recentEvents: @escaping (Int) async -> [LifecycleEventDTO]
    ) {
        self.getStatus = getStatus
        self.setPaused = setPaused
        self.restoreNow = restoreNow
        self.clearSnapshot = clearSnapshot
        self.recentEvents = recentEvents
    }
}

public final class OfficeResumeDaemonService: NSObject, OfficeResumeDaemonXPCProtocol {
    private let handlers: DaemonServiceHandlers
    private let encoder = JSONEncoder()

    public init(handlers: DaemonServiceHandlers) {
        self.handlers = handlers
    }

    public convenience init(store: DaemonStateStore = DaemonStateStore()) {
        self.init(handlers: Self.defaultHandlers(store: store))
    }

    public func getStatus(reply: @escaping (NSData?) -> Void) {
        Task {
            let status = await handlers.getStatus()
            reply(try? encoder.encode(status) as NSData)
        }
    }

    public func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void) {
        Task {
            let ok = await handlers.setPaused(paused)
            reply(ok)
        }
    }

    public func restoreNow(_ appRaw: String?, reply: @escaping (NSData?) -> Void) {
        Task {
            let app = appRaw.flatMap { OfficeApp(rawValue: $0) }
            let result = await handlers.restoreNow(app)
            reply(try? encoder.encode(result) as NSData)
        }
    }

    public func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void) {
        Task {
            let app = appRaw.flatMap { OfficeApp(rawValue: $0) }
            let ok = await handlers.clearSnapshot(app)
            reply(ok)
        }
    }

    public func recentEvents(_ limit: Int, reply: @escaping (NSData?) -> Void) {
        Task {
            let items = await handlers.recentEvents(limit)
            reply(try? encoder.encode(items) as NSData)
        }
    }

    private static func defaultHandlers(store: DaemonStateStore) -> DaemonServiceHandlers {
        DaemonServiceHandlers(
            getStatus: {
                store.currentStatus()
            },
            setPaused: { paused in
                store.setPaused(paused)
            },
            restoreNow: { app in
                if let app {
                    store.recordEvent(app: app, type: .restoreStarted)
                    store.recordEvent(app: app, type: .restoreSucceeded)
                } else {
                    for app in [OfficeApp.word, .excel, .powerpoint, .outlook] {
                        store.recordEvent(app: app, type: .restoreStarted)
                        store.recordEvent(app: app, type: .restoreSucceeded)
                    }
                }
                return RestoreCommandResultDTO(succeeded: true, restoredCount: 0, failedCount: 0)
            },
            clearSnapshot: { app in
                if let app {
                    store.recordEvent(app: app, type: .stateCaptured, details: ["source": "clearSnapshot"])
                }
                return true
            },
            recentEvents: { limit in
                store.recentEvents(limit: limit)
            }
        )
    }
}

public final class DaemonListenerHost: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let service: OfficeResumeDaemonService

    public init(service: OfficeResumeDaemonService = OfficeResumeDaemonService()) {
        self.listener = NSXPCListener(machServiceName: DaemonXPCConstants.machServiceName)
        self.service = service
        super.init()
        self.listener.delegate = self
    }

    public func resume() {
        listener.resume()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: OfficeResumeDaemonXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = {}
        newConnection.interruptionHandler = {}
        newConnection.resume()
        return true
    }

    public func serviceInstance() -> OfficeResumeDaemonService {
        service
    }
}

public final class DaemonXPCClient {
    private var connection: NSXPCConnection?
    private let decoder = JSONDecoder()

    public init() {}

    public func fetchStatus(_ completion: @escaping (Result<DaemonStatusDTO, Error>) -> Void) {
        withRemote { proxy in
            proxy.getStatus { data in
                guard let data else {
                    completion(.failure(DaemonXPCError.decodingFailed))
                    return
                }
                do {
                    let status = try self.decoder.decode(DaemonStatusDTO.self, from: data as Data)
                    completion(.success(status))
                } catch {
                    completion(.failure(error))
                }
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    public func setPaused(_ paused: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        withRemote { proxy in
            proxy.setPaused(paused) { ok in
                completion(.success(ok))
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    public func restoreNow(app: OfficeApp?, completion: @escaping (Result<RestoreCommandResultDTO, Error>) -> Void) {
        withRemote { proxy in
            proxy.restoreNow(app?.rawValue) { data in
                guard let data else {
                    completion(.failure(DaemonXPCError.decodingFailed))
                    return
                }
                do {
                    let decoded = try self.decoder.decode(RestoreCommandResultDTO.self, from: data as Data)
                    completion(.success(decoded))
                } catch {
                    completion(.failure(error))
                }
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    public func clearSnapshot(app: OfficeApp?, completion: @escaping (Result<Bool, Error>) -> Void) {
        withRemote { proxy in
            proxy.clearSnapshot(app?.rawValue) { ok in
                completion(.success(ok))
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    public func fetchRecentEvents(limit: Int, completion: @escaping (Result<[LifecycleEventDTO], Error>) -> Void) {
        withRemote { proxy in
            proxy.recentEvents(limit) { data in
                guard let data else {
                    completion(.failure(DaemonXPCError.decodingFailed))
                    return
                }
                do {
                    let decoded = try self.decoder.decode([LifecycleEventDTO].self, from: data as Data)
                    completion(.success(decoded))
                } catch {
                    completion(.failure(error))
                }
            }
        } onFailure: { error in
            completion(.failure(error))
        }
    }

    private func withRemote(
        _ body: @escaping (OfficeResumeDaemonXPCProtocol) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        do {
            let proxy = try remoteProxy()
            body(proxy)
        } catch {
            onFailure(error)
        }
    }

    private func remoteProxy() throws -> OfficeResumeDaemonXPCProtocol {
        let connection = try ensureConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? OfficeResumeDaemonXPCProtocol else {
            throw DaemonXPCError.connectionFailed
        }
        return proxy
    }

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection {
            return connection
        }

        let newConnection = NSXPCConnection(machServiceName: DaemonXPCConstants.machServiceName, options: [])
        newConnection.remoteObjectInterface = NSXPCInterface(with: OfficeResumeDaemonXPCProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.connection = nil
        }
        newConnection.resume()

        connection = newConnection
        return newConnection
    }
}
