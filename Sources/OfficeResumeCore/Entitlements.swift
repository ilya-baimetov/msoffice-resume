import Foundation

public protocol RemoteEntitlementValidating {
    func fetchCurrentEntitlement() async throws -> EntitlementState
}

public struct FreePassConfig: Codable {
    public let localModeEnabled: Bool
    public let freePassDeviceIDs: [String]
    public let freePassEmails: [String]

    public init(
        localModeEnabled: Bool = false,
        freePassDeviceIDs: [String] = [],
        freePassEmails: [String] = []
    ) {
        self.localModeEnabled = localModeEnabled
        self.freePassDeviceIDs = freePassDeviceIDs
        self.freePassEmails = freePassEmails
    }
}

public enum EntitlementOverrideEvaluator {
    public static func freePassFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = appSupport
            .appendingPathComponent("com.pragprod.msofficeresume", isDirectory: true)
            .appendingPathComponent("entitlements", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("free-pass-v1.json")
    }

    public static func currentDeviceID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["OFFICE_RESUME_DEVICE_ID"], !normalized(explicit).isEmpty {
            return normalized(explicit)
        }

        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let raw = "\(NSUserName())@\(host)"
        return normalized(raw)
    }

    public static func overrideState(
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        freePassFileURL overrideFileURL: URL? = nil
    ) -> EntitlementState? {
        if isEnabled(environment["OFFICE_RESUME_LOCAL_MODE"]) {
            return activeFreePassState(now: now)
        }

        let envDeviceIDs = csvSet(from: environment["OFFICE_RESUME_FREE_PASS_DEVICE_IDS"])
        let envEmails = csvSet(from: environment["OFFICE_RESUME_FREE_PASS_EMAILS"])

        let fileConfig = loadConfig(
            fileManager: fileManager,
            overrideFileURL: overrideFileURL
        ) ?? FreePassConfig()

        if fileConfig.localModeEnabled {
            return activeFreePassState(now: now)
        }

        let configuredDeviceIDs = Set(fileConfig.freePassDeviceIDs.map(normalized))
        let configuredEmails = Set(fileConfig.freePassEmails.map(normalized))

        let allDeviceIDs = envDeviceIDs.union(configuredDeviceIDs)
        let allEmails = envEmails.union(configuredEmails)

        let currentDeviceID = currentDeviceID(environment: environment)
        if allDeviceIDs.contains(currentDeviceID) {
            return activeFreePassState(now: now)
        }

        if let rawEmail = environment["OFFICE_RESUME_USER_EMAIL"] {
            let normalizedEmail = normalized(rawEmail)
            if !normalizedEmail.isEmpty, allEmails.contains(normalizedEmail) {
                return activeFreePassState(now: now)
            }
        }

        return nil
    }

    private static func loadConfig(fileManager: FileManager, overrideFileURL: URL?) -> FreePassConfig? {
        do {
            let url = try overrideFileURL ?? freePassFileURL(fileManager: fileManager)
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }

            let data = try Data(contentsOf: url)
            if data.isEmpty {
                return nil
            }

            let decoder = JSONDecoder()
            return try decoder.decode(FreePassConfig.self, from: data)
        } catch {
            return nil
        }
    }

    private static func csvSet(from raw: String?) -> Set<String> {
        guard let raw else {
            return []
        }

        return Set(
            raw
                .split(separator: ",")
                .map(String.init)
                .map(normalized)
                .filter { !$0.isEmpty }
        )
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else {
            return false
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func activeFreePassState(now: Date) -> EntitlementState {
        let validUntil = Calendar.current.date(byAdding: .year, value: 10, to: now)
        return EntitlementState(
            isActive: true,
            plan: .yearly,
            validUntil: validUntil,
            trialEndsAt: nil,
            lastValidatedAt: now
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public enum EntitlementPolicy {
    public static let trialLengthDays = 14
    public static let offlineGraceDays = 7

    public static func trialEndsAt(firstSeenAt: Date, now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: trialLengthDays, to: firstSeenAt) ?? now
    }

    public static func isTrialActive(firstSeenAt: Date, now: Date) -> Bool {
        now < trialEndsAt(firstSeenAt: firstSeenAt, now: now)
    }

    public static func applyOfflineGrace(to state: EntitlementState, now: Date) -> EntitlementState {
        guard state.isActive else {
            return state
        }

        guard let lastValidatedAt = state.lastValidatedAt else {
            return EntitlementState(
                isActive: false,
                plan: .none,
                validUntil: state.validUntil,
                trialEndsAt: state.trialEndsAt,
                lastValidatedAt: state.lastValidatedAt
            )
        }

        guard let cutoff = Calendar.current.date(byAdding: .day, value: offlineGraceDays, to: lastValidatedAt) else {
            return state
        }

        if now <= cutoff {
            return state
        }

        return EntitlementState(
            isActive: false,
            plan: .none,
            validUntil: state.validUntil,
            trialEndsAt: state.trialEndsAt,
            lastValidatedAt: state.lastValidatedAt
        )
    }
}

public actor EntitlementFileStore {
    private struct TrialMetadata: Codable {
        let firstSeenAt: Date
    }

    private let fileManager: FileManager
    private let cacheURL: URL
    private let trialURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) throws {
        self.fileManager = fileManager

        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = appSupport
                .appendingPathComponent("com.pragprod.msofficeresume", isDirectory: true)
                .appendingPathComponent("entitlements", isDirectory: true)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cacheURL = directory.appendingPathComponent("entitlement-cache-v1.json")
        self.trialURL = directory.appendingPathComponent("trial-v1.json")

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadCachedState() async throws -> EntitlementState? {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        if data.isEmpty {
            return nil
        }

        return try decoder.decode(EntitlementState.self, from: data)
    }

    public func saveCachedState(_ state: EntitlementState) async throws {
        let data = try encoder.encode(state)
        try write(data: data, to: cacheURL)
    }

    public func loadOrCreateTrialStart(now: Date) async throws -> Date {
        if fileManager.fileExists(atPath: trialURL.path) {
            let data = try Data(contentsOf: trialURL)
            if !data.isEmpty {
                let decoded = try decoder.decode(TrialMetadata.self, from: data)
                return decoded.firstSeenAt
            }
        }

        let metadata = TrialMetadata(firstSeenAt: now)
        let data = try encoder.encode(metadata)
        try write(data: data, to: trialURL)
        return now
    }

    private func write(data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public actor TrialEntitlementProvider: EntitlementProvider {
    private let store: EntitlementFileStore
    private let remoteValidator: RemoteEntitlementValidating?
    private let now: () -> Date
    private let overrideEnvironment: [String: String]
    private let overrideFreePassFileURL: URL?
    private let overrideFileManager: FileManager

    public init(
        store: EntitlementFileStore,
        remoteValidator: RemoteEntitlementValidating? = nil,
        now: @escaping () -> Date = Date.init,
        overrideEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        overrideFreePassFileURL: URL? = nil,
        overrideFileManager: FileManager = .default
    ) {
        self.store = store
        self.remoteValidator = remoteValidator
        self.now = now
        self.overrideEnvironment = overrideEnvironment
        self.overrideFreePassFileURL = overrideFreePassFileURL
        self.overrideFileManager = overrideFileManager
    }

    public func currentState() async -> EntitlementState {
        let now = now()

        if let override = EntitlementOverrideEvaluator.overrideState(
            now: now,
            environment: overrideEnvironment,
            fileManager: overrideFileManager,
            freePassFileURL: overrideFreePassFileURL
        ) {
            return override
        }

        do {
            if let cached = try await store.loadCachedState() {
                return EntitlementPolicy.applyOfflineGrace(to: cached, now: now)
            }

            let trialStart = try await store.loadOrCreateTrialStart(now: now)
            return trialState(trialStart: trialStart, now: now)
        } catch {
            return EntitlementState(isActive: false, plan: .none, validUntil: nil, trialEndsAt: nil, lastValidatedAt: nil)
        }
    }

    public func refresh() async throws -> EntitlementState {
        let now = now()

        if let override = EntitlementOverrideEvaluator.overrideState(
            now: now,
            environment: overrideEnvironment,
            fileManager: overrideFileManager,
            freePassFileURL: overrideFreePassFileURL
        ) {
            try? await store.saveCachedState(override)
            return override
        }

        if let remoteValidator {
            do {
                let state = try await remoteValidator.fetchCurrentEntitlement()
                let stamped = EntitlementState(
                    isActive: state.isActive,
                    plan: state.plan,
                    validUntil: state.validUntil,
                    trialEndsAt: state.trialEndsAt,
                    lastValidatedAt: now
                )
                try await store.saveCachedState(stamped)
                return stamped
            } catch {
                if let cached = try await store.loadCachedState() {
                    return EntitlementPolicy.applyOfflineGrace(to: cached, now: now)
                }
            }
        }

        let trialStart = try await store.loadOrCreateTrialStart(now: now)
        let trial = trialState(trialStart: trialStart, now: now)
        try await store.saveCachedState(trial)
        return trial
    }

    public func canRestore() async -> Bool {
        (await currentState()).isActive
    }

    public func canMonitor() async -> Bool {
        (await currentState()).isActive
    }

    private func trialState(trialStart: Date, now: Date) -> EntitlementState {
        let trialEndsAt = EntitlementPolicy.trialEndsAt(firstSeenAt: trialStart, now: now)
        let active = now < trialEndsAt
        return EntitlementState(
            isActive: active,
            plan: active ? .trial : .none,
            validUntil: trialEndsAt,
            trialEndsAt: trialEndsAt,
            lastValidatedAt: now
        )
    }
}

public actor StoreKitEntitlementProvider: EntitlementProvider {
    private let base: TrialEntitlementProvider

    public init(store: EntitlementFileStore, remoteValidator: RemoteEntitlementValidating? = nil, now: @escaping () -> Date = Date.init) {
        self.base = TrialEntitlementProvider(store: store, remoteValidator: remoteValidator, now: now)
    }

    public func currentState() async -> EntitlementState {
        await base.currentState()
    }

    public func refresh() async throws -> EntitlementState {
        try await base.refresh()
    }

    public func canRestore() async -> Bool {
        await base.canRestore()
    }

    public func canMonitor() async -> Bool {
        await base.canMonitor()
    }
}

public actor StripeEntitlementProvider: EntitlementProvider {
    private let base: TrialEntitlementProvider

    public init(store: EntitlementFileStore, remoteValidator: RemoteEntitlementValidating? = nil, now: @escaping () -> Date = Date.init) {
        self.base = TrialEntitlementProvider(store: store, remoteValidator: remoteValidator, now: now)
    }

    public func currentState() async -> EntitlementState {
        await base.currentState()
    }

    public func refresh() async throws -> EntitlementState {
        try await base.refresh()
    }

    public func canRestore() async -> Bool {
        await base.canRestore()
    }

    public func canMonitor() async -> Bool {
        await base.canMonitor()
    }
}

public struct StripeEntitlementValidator: RemoteEntitlementValidating {
    public struct Config {
        public let endpoint: URL
        public let bearerToken: String

        public init(endpoint: URL, bearerToken: String) {
            self.endpoint = endpoint
            self.bearerToken = bearerToken
        }
    }

    private struct Response: Decodable {
        let isActive: Bool
        let plan: String
        let validUntil: Date?
        let trialEndsAt: Date?
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetchCurrentEntitlement() async throws -> EntitlementState {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Response.self, from: data)

        let plan: EntitlementState.Plan
        switch decoded.plan {
        case "trial":
            plan = .trial
        case "monthly":
            plan = .monthly
        case "yearly":
            plan = .yearly
        default:
            plan = .none
        }

        return EntitlementState(
            isActive: decoded.isActive,
            plan: plan,
            validUntil: decoded.validUntil,
            trialEndsAt: decoded.trialEndsAt,
            lastValidatedAt: Date()
        )
    }
}
