import Foundation

public enum DaemonXPCError: Error, LocalizedError {
    case endpointMissing
    case endpointDecodeFailed
    case connectionFailed
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .endpointMissing:
            return "Helper endpoint is unavailable."
        case .endpointDecodeFailed:
            return "Unable to decode helper endpoint."
        case .connectionFailed:
            return "Unable to connect to helper XPC service."
        case .encodingFailed:
            return "Unable to encode request payload."
        case .decodingFailed:
            return "Unable to decode response payload."
        }
    }
}

public enum DaemonEndpointStore {
    public static func endpointFileURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DaemonXPCError.endpointMissing
        }

        let directory = appSupport
            .appendingPathComponent("com.pragprod.msofficeresume", isDirectory: true)
            .appendingPathComponent("ipc", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("helper.endpoint")
    }

    public static func save(endpoint: NSXPCListenerEndpoint) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: endpoint, requiringSecureCoding: true)
        let url = try endpointFileURL()
        try data.write(to: url, options: [.atomic])
    }

    public static func load() throws -> NSXPCListenerEndpoint {
        let url = try endpointFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DaemonXPCError.endpointMissing
        }

        let data = try Data(contentsOf: url)
        let object = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSXPCListenerEndpoint.self, from: data)
        guard let endpoint = object else {
            throw DaemonXPCError.endpointDecodeFailed
        }
        return endpoint
    }
}

@objc public protocol OfficeResumeDaemonXPCProtocol {
    func getStatus(reply: @escaping (NSData?) -> Void)
    func setPollingInterval(_ value: String, reply: @escaping (Bool) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (NSData?) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
    func recentEvents(_ limit: Int, reply: @escaping (NSData?) -> Void)
}

public final class DaemonStateStore {
    private let queue = DispatchQueue(label: "com.pragprod.msofficeresume.daemon-state")
    private var status = DaemonStatusDTO(
        isPaused: false,
        pollingInterval: .fifteenSeconds,
        helperRunning: true,
        entitlementActive: true,
        latestSnapshotCapturedAt: [:],
        unsupportedApps: OfficeBundleRegistry.unsupportedApps
    )
    private var events: [LifecycleEventDTO] = []

    public init() {}

    public func currentStatus() -> DaemonStatusDTO {
        queue.sync { status }
    }

    @discardableResult
    public func setPollingInterval(_ interval: PollingInterval) -> Bool {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                pollingInterval: interval,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
            return true
        }
    }

    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: paused,
                pollingInterval: status.pollingInterval,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
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
                pollingInterval: status.pollingInterval,
                helperRunning: running,
                entitlementActive: status.entitlementActive,
                latestSnapshotCapturedAt: status.latestSnapshotCapturedAt,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func setEntitlementActive(_ isActive: Bool) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                pollingInterval: status.pollingInterval,
                helperRunning: status.helperRunning,
                entitlementActive: isActive,
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
                pollingInterval: status.pollingInterval,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
                latestSnapshotCapturedAt: updated,
                unsupportedApps: status.unsupportedApps
            )
        }
    }

    public func setLatestSnapshots(_ snapshots: [OfficeApp: Date]) {
        queue.sync {
            status = DaemonStatusDTO(
                isPaused: status.isPaused,
                pollingInterval: status.pollingInterval,
                helperRunning: status.helperRunning,
                entitlementActive: status.entitlementActive,
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
    public let setPollingInterval: (PollingInterval) async -> Bool
    public let setPaused: (Bool) async -> Bool
    public let restoreNow: (OfficeApp?) async -> RestoreCommandResultDTO
    public let clearSnapshot: (OfficeApp?) async -> Bool
    public let recentEvents: (Int) async -> [LifecycleEventDTO]

    public init(
        getStatus: @escaping () async -> DaemonStatusDTO,
        setPollingInterval: @escaping (PollingInterval) async -> Bool,
        setPaused: @escaping (Bool) async -> Bool,
        restoreNow: @escaping (OfficeApp?) async -> RestoreCommandResultDTO,
        clearSnapshot: @escaping (OfficeApp?) async -> Bool,
        recentEvents: @escaping (Int) async -> [LifecycleEventDTO]
    ) {
        self.getStatus = getStatus
        self.setPollingInterval = setPollingInterval
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

    public func setPollingInterval(_ value: String, reply: @escaping (Bool) -> Void) {
        guard let interval = PollingInterval(rawValue: value) else {
            reply(false)
            return
        }

        Task {
            let ok = await handlers.setPollingInterval(interval)
            reply(ok)
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
            setPollingInterval: { interval in
                store.setPollingInterval(interval)
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
                    store.recordEvent(app: app, type: .statePolled, details: ["source": "clearSnapshot"])
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
        self.listener = NSXPCListener.anonymous()
        self.service = service
        super.init()
        self.listener.delegate = self
    }

    public func resume() throws {
        listener.resume()
        try DaemonEndpointStore.save(endpoint: listener.endpoint)
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

    public func setPollingInterval(_ interval: PollingInterval, completion: @escaping (Result<Bool, Error>) -> Void) {
        withRemote { proxy in
            proxy.setPollingInterval(interval.rawValue) { ok in
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

        let endpoint = try DaemonEndpointStore.load()
        let newConnection = NSXPCConnection(listenerEndpoint: endpoint)
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
