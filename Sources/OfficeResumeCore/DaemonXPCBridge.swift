import Foundation

public enum DaemonXPCConstants {
    public static let endpointFileName = "daemon-xpc-endpoint-v1.data"
}

public enum DaemonXPCError: Error, LocalizedError {
    case connectionFailed
    case decodingFailed
    case requestTimedOut

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Unable to connect to helper XPC service."
        case .decodingFailed:
            return "Unable to decode response payload."
        case .requestTimedOut:
            return "Helper request timed out."
        }
    }
}

@objc public protocol OfficeResumeDaemonXPCProtocol {
    func getStatus(reply: @escaping (NSData?) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (NSData?) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
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

}

public struct DaemonServiceHandlers {
    public let getStatus: () async -> DaemonStatusDTO
    public let setPaused: (Bool) async -> Bool
    public let restoreNow: (OfficeApp?) async -> RestoreCommandResultDTO
    public let clearSnapshot: (OfficeApp?) async -> Bool

    public init(
        getStatus: @escaping () async -> DaemonStatusDTO,
        setPaused: @escaping (Bool) async -> Bool,
        restoreNow: @escaping (OfficeApp?) async -> RestoreCommandResultDTO,
        clearSnapshot: @escaping (OfficeApp?) async -> Bool
    ) {
        self.getStatus = getStatus
        self.setPaused = setPaused
        self.restoreNow = restoreNow
        self.clearSnapshot = clearSnapshot
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

    private static func defaultHandlers(store: DaemonStateStore) -> DaemonServiceHandlers {
        DaemonServiceHandlers(
            getStatus: {
                store.currentStatus()
            },
            setPaused: { paused in
                store.setPaused(paused)
            },
            restoreNow: { _ in
                return RestoreCommandResultDTO(succeeded: true, restoredCount: 0, failedCount: 0)
            },
            clearSnapshot: { _ in
                return true
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

    public func resume() {
        listener.resume()
    }

    public func persistEndpoint() throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: listener.endpoint, requiringSecureCoding: false)
        try DaemonEndpointStore.writeEndpointData(data)
    }

    public func clearEndpoint() {
        try? DaemonEndpointStore.clear()
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
    private let requestTimeoutSeconds: TimeInterval = 1.5

    public init() {}

    public func fetchStatus(_ completion: @escaping (Result<DaemonStatusDTO, Error>) -> Void) {
        sendRequest(completion: completion) { proxy, resolve in
            proxy.getStatus { data in
                guard let data else {
                    resolve(.failure(DaemonXPCError.decodingFailed))
                    return
                }

                do {
                    let status = try self.decoder.decode(DaemonStatusDTO.self, from: data as Data)
                    resolve(.success(status))
                } catch {
                    resolve(.failure(error))
                }
            }
        }
    }

    public func setPaused(_ paused: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        sendRequest(completion: completion) { proxy, resolve in
            proxy.setPaused(paused) { ok in
                resolve(.success(ok))
            }
        }
    }

    public func restoreNow(app: OfficeApp?, completion: @escaping (Result<RestoreCommandResultDTO, Error>) -> Void) {
        sendRequest(completion: completion) { proxy, resolve in
            proxy.restoreNow(app?.rawValue) { data in
                guard let data else {
                    resolve(.failure(DaemonXPCError.decodingFailed))
                    return
                }
                do {
                    let decoded = try self.decoder.decode(RestoreCommandResultDTO.self, from: data as Data)
                    resolve(.success(decoded))
                } catch {
                    resolve(.failure(error))
                }
            }
        }
    }

    public func clearSnapshot(app: OfficeApp?, completion: @escaping (Result<Bool, Error>) -> Void) {
        sendRequest(completion: completion) { proxy, resolve in
            proxy.clearSnapshot(app?.rawValue) { ok in
                resolve(.success(ok))
            }
        }
    }

    private func sendRequest<T>(
        completion: @escaping (Result<T, Error>) -> Void,
        request: @escaping (_ proxy: OfficeResumeDaemonXPCProtocol, _ resolve: @escaping (Result<T, Error>) -> Void) -> Void
    ) {
        let resolve = singleShot(completion)

        do {
            let proxy = try remoteProxy { [weak self] error in
                self?.invalidateConnection()
                resolve(.failure(error))
            }
            request(proxy, resolve)
            scheduleTimeout(resolve)
        } catch {
            resolve(.failure(error))
        }
    }

    private func remoteProxy(onError: @escaping (Error) -> Void) throws -> OfficeResumeDaemonXPCProtocol {
        let connection = try ensureConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? OfficeResumeDaemonXPCProtocol else {
            throw DaemonXPCError.connectionFailed
        }
        return proxy
    }

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection {
            return connection
        }

        guard let endpoint = try DaemonEndpointStore.readEndpoint() else {
            throw DaemonXPCError.connectionFailed
        }

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

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func singleShot<T>(
        _ completion: @escaping (Result<T, Error>) -> Void
    ) -> (Result<T, Error>) -> Void {
        let lock = NSLock()
        var resolved = false

        return { result in
            lock.lock()
            defer { lock.unlock() }
            guard !resolved else {
                return
            }
            resolved = true
            completion(result)
        }
    }

    private func scheduleTimeout<T>(
        _ completion: @escaping (Result<T, Error>) -> Void
    ) {
        DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeoutSeconds) {
            completion(.failure(DaemonXPCError.requestTimedOut))
        }
    }
}

private enum DaemonEndpointStore {
    static func writeEndpointData(_ data: Data, fileManager: FileManager = .default) throws {
        let url = try endpointFileURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func readEndpoint(fileManager: FileManager = .default) throws -> NSXPCListenerEndpoint? {
        let url = try endpointFileURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSXPCListenerEndpoint.self, from: data)
    }

    static func clear(fileManager: FileManager = .default) throws {
        let url = try endpointFileURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private static func endpointFileURL(fileManager: FileManager) throws -> URL {
        let root = try RuntimeConfiguration.appGroupOrFallbackRoot(fileManager: fileManager)
        return root
            .appendingPathComponent("ipc", isDirectory: true)
            .appendingPathComponent(DaemonXPCConstants.endpointFileName)
    }
}
