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
    func openAccessibilitySettings(_ reply: @escaping (Bool) -> Void)
}

public struct DaemonStatusDTO: Codable {
    public let isPaused: Bool
    public let helperRunning: Bool
    public let accessibilityTrusted: Bool
    public let entitlementActive: Bool
    public let entitlementPlan: EntitlementState.Plan
    public let entitlementValidUntil: Date?
    public let entitlementTrialEndsAt: Date?
    public let latestSnapshotCapturedAt: [OfficeApp: Date]
    public let unsupportedApps: [OfficeApp]

    private enum CodingKeys: String, CodingKey {
        case isPaused
        case helperRunning
        case accessibilityTrusted
        case entitlementActive
        case entitlementPlan
        case entitlementValidUntil
        case entitlementTrialEndsAt
        case latestSnapshotCapturedAt
        case unsupportedApps
    }

    public init(
        isPaused: Bool,
        helperRunning: Bool,
        accessibilityTrusted: Bool = false,
        entitlementActive: Bool,
        entitlementPlan: EntitlementState.Plan,
        entitlementValidUntil: Date?,
        entitlementTrialEndsAt: Date?,
        latestSnapshotCapturedAt: [OfficeApp: Date],
        unsupportedApps: [OfficeApp]
    ) {
        self.isPaused = isPaused
        self.helperRunning = helperRunning
        self.accessibilityTrusted = accessibilityTrusted
        self.entitlementActive = entitlementActive
        self.entitlementPlan = entitlementPlan
        self.entitlementValidUntil = entitlementValidUntil
        self.entitlementTrialEndsAt = entitlementTrialEndsAt
        self.latestSnapshotCapturedAt = latestSnapshotCapturedAt
        self.unsupportedApps = unsupportedApps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        helperRunning = try container.decode(Bool.self, forKey: .helperRunning)
        accessibilityTrusted = try container.decodeIfPresent(Bool.self, forKey: .accessibilityTrusted) ?? false
        entitlementActive = try container.decode(Bool.self, forKey: .entitlementActive)
        entitlementPlan = try container.decode(EntitlementState.Plan.self, forKey: .entitlementPlan)
        entitlementValidUntil = try container.decodeIfPresent(Date.self, forKey: .entitlementValidUntil)
        entitlementTrialEndsAt = try container.decodeIfPresent(Date.self, forKey: .entitlementTrialEndsAt)
        latestSnapshotCapturedAt = try container.decode([OfficeApp: Date].self, forKey: .latestSnapshotCapturedAt)
        unsupportedApps = try container.decode([OfficeApp].self, forKey: .unsupportedApps)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(helperRunning, forKey: .helperRunning)
        try container.encode(accessibilityTrusted, forKey: .accessibilityTrusted)
        try container.encode(entitlementActive, forKey: .entitlementActive)
        try container.encode(entitlementPlan, forKey: .entitlementPlan)
        try container.encodeIfPresent(entitlementValidUntil, forKey: .entitlementValidUntil)
        try container.encodeIfPresent(entitlementTrialEndsAt, forKey: .entitlementTrialEndsAt)
        try container.encode(latestSnapshotCapturedAt, forKey: .latestSnapshotCapturedAt)
        try container.encode(unsupportedApps, forKey: .unsupportedApps)
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
