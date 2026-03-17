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

public protocol AccountProvider {
    func currentAccountState() async -> AccountState
    func refreshAccountState() async throws -> AccountState
    func requestSignInLink(email: String) async throws
    func handleIncomingURL(_ url: URL) async throws -> Bool
    func billingActionURL() async throws -> URL?
    func signOut() async throws
}

public protocol DaemonXPC {
    func getStatus(_ reply: @escaping (DaemonStatusDTO) -> Void)
    func setPaused(_ paused: Bool, reply: @escaping (Bool) -> Void)
    func restoreNow(_ appRaw: String?, reply: @escaping (RestoreCommandResultDTO) -> Void)
    func clearSnapshot(_ appRaw: String?, reply: @escaping (Bool) -> Void)
}

public struct DaemonStatusDTO: Codable {
    public let isPaused: Bool
    public let helperRunning: Bool
    public let entitlementActive: Bool
    public let entitlementPlan: EntitlementState.Plan
    public let entitlementValidUntil: Date?
    public let entitlementTrialEndsAt: Date?
    public let latestSnapshotCapturedAt: [OfficeApp: Date]
    public let unsupportedApps: [OfficeApp]

    public init(
        isPaused: Bool,
        helperRunning: Bool,
        entitlementActive: Bool,
        entitlementPlan: EntitlementState.Plan,
        entitlementValidUntil: Date?,
        entitlementTrialEndsAt: Date?,
        latestSnapshotCapturedAt: [OfficeApp: Date],
        unsupportedApps: [OfficeApp]
    ) {
        self.isPaused = isPaused
        self.helperRunning = helperRunning
        self.entitlementActive = entitlementActive
        self.entitlementPlan = entitlementPlan
        self.entitlementValidUntil = entitlementValidUntil
        self.entitlementTrialEndsAt = entitlementTrialEndsAt
        self.latestSnapshotCapturedAt = latestSnapshotCapturedAt
        self.unsupportedApps = unsupportedApps
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
