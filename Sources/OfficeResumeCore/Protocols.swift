import Foundation

public protocol OfficeAdapter {
    var app: OfficeApp { get }
    func fetchState() async throws -> AppSnapshot
    func restore(snapshot: AppSnapshot) async throws -> RestoreResult
    func forceSaveUntitled(state: AppSnapshot) async throws -> [DocumentSnapshot]
}

public protocol EntitlementProvider {
    func currentState() async -> EntitlementState
    func refresh() async throws -> EntitlementState
    func canRestore() async -> Bool
    func canMonitor() async -> Bool
}

public protocol DaemonXPC {
    func getStatus(_ reply: @escaping (DaemonStatusDTO) -> Void)
    func setPollingInterval(_ value: String, reply: @escaping (Bool) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (RestoreCommandResultDTO) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
    func recentEvents(_ limit: Int, reply: @escaping ([LifecycleEventDTO]) -> Void)
}

public struct DaemonStatusDTO: Codable {
    public let isPaused: Bool
    public let pollingInterval: PollingInterval
    public let helperRunning: Bool
    public let entitlementActive: Bool

    public init(
        isPaused: Bool,
        pollingInterval: PollingInterval,
        helperRunning: Bool,
        entitlementActive: Bool
    ) {
        self.isPaused = isPaused
        self.pollingInterval = pollingInterval
        self.helperRunning = helperRunning
        self.entitlementActive = entitlementActive
    }
}

public struct RestoreCommandResultDTO: Codable {
    public let succeeded: Bool
    public let restoredCount: Int
    public let failedCount: Int

    public init(succeeded: Bool, restoredCount: Int, failedCount: Int) {
        self.succeeded = succeeded
        self.restoredCount = restoredCount
        self.failedCount = failedCount
    }
}

public struct LifecycleEventDTO: Codable {
    public let app: OfficeApp
    public let type: LifecycleEventType
    public let timestamp: Date

    public init(app: OfficeApp, type: LifecycleEventType, timestamp: Date) {
        self.app = app
        self.type = type
        self.timestamp = timestamp
    }
}
