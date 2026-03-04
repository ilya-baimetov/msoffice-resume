import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

public protocol RemoteEntitlementValidating {
    func fetchCurrentEntitlement() async throws -> EntitlementState
}

public enum DebugEntitlementBypassEvaluator {
    public static func overrideState(
        now: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EntitlementState? {
        guard RuntimeConfiguration.isDebugEntitlementBypassEnabled(environment: environment) else {
            return nil
        }

        let validUntil = Calendar.current.date(byAdding: .year, value: 10, to: now)
        return EntitlementState(
            isActive: true,
            plan: .yearly,
            validUntil: validUntil,
            trialEndsAt: nil,
            lastValidatedAt: now
        )
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
            directory = try RuntimeConfiguration
                .appGroupOrFallbackRoot(fileManager: fileManager)
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

    public init(
        store: EntitlementFileStore,
        remoteValidator: RemoteEntitlementValidating? = nil,
        now: @escaping () -> Date = Date.init,
        overrideEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.remoteValidator = remoteValidator
        self.now = now
        self.overrideEnvironment = overrideEnvironment
    }

    public func currentState() async -> EntitlementState {
        let now = now()

        if let override = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            environment: overrideEnvironment
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

        if let override = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            environment: overrideEnvironment
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
        let resolvedValidator: RemoteEntitlementValidating?
#if canImport(StoreKit)
        if remoteValidator == nil, #available(macOS 14.0, *) {
            resolvedValidator = StoreKitEntitlementValidator()
        } else {
            resolvedValidator = remoteValidator
        }
#else
        resolvedValidator = remoteValidator
#endif
        self.base = TrialEntitlementProvider(store: store, remoteValidator: resolvedValidator, now: now)
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

        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Config? {
            guard
                let endpointRaw = environment["OFFICE_RESUME_ENTITLEMENT_ENDPOINT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !endpointRaw.isEmpty,
                let endpoint = URL(string: endpointRaw),
                let token = environment["OFFICE_RESUME_SESSION_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !token.isEmpty
            else {
                return nil
            }

            return Config(endpoint: endpoint, bearerToken: token)
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

#if canImport(StoreKit)
@available(macOS 14.0, *)
public struct StoreKitEntitlementValidator: RemoteEntitlementValidating {
    private let productIDs: Set<String>

    public init(productIDs: Set<String> = ["officeresume.monthly", "officeresume.yearly"]) {
        self.productIDs = productIDs
    }

    public func fetchCurrentEntitlement() async throws -> EntitlementState {
        var newestTransaction: Transaction?

        for await entitlement in Transaction.currentEntitlements {
            guard case let .verified(transaction) = entitlement else {
                continue
            }

            guard productIDs.contains(transaction.productID) else {
                continue
            }

            if transaction.revocationDate != nil || transaction.isUpgraded {
                continue
            }

            if let current = newestTransaction {
                let currentExpiry = current.expirationDate ?? .distantFuture
                let candidateExpiry = transaction.expirationDate ?? .distantFuture
                if candidateExpiry > currentExpiry {
                    newestTransaction = transaction
                }
            } else {
                newestTransaction = transaction
            }
        }

        guard let transaction = newestTransaction else {
            return EntitlementState(
                isActive: false,
                plan: .none,
                validUntil: nil,
                trialEndsAt: nil,
                lastValidatedAt: Date()
            )
        }

        let now = Date()
        let validUntil = transaction.expirationDate
        let isActive = validUntil.map { $0 > now } ?? true

        let lowerProductID = transaction.productID.lowercased()
        let plan: EntitlementState.Plan
        if lowerProductID.contains("year") {
            plan = .yearly
        } else if lowerProductID.contains("month") {
            plan = .monthly
        } else {
            plan = .monthly
        }

        return EntitlementState(
            isActive: isActive,
            plan: isActive ? plan : .none,
            validUntil: validUntil,
            trialEndsAt: transaction.offerType == .introductory ? validUntil : nil,
            lastValidatedAt: now
        )
    }
}
#endif

public enum EntitlementProviderFactory {
    public static func makeProvider(
        channel: DistributionChannel,
        store: EntitlementFileStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EntitlementProvider {
        switch channel {
        case .mas:
            return StoreKitEntitlementProvider(store: store)
        case .direct:
            if let config = StripeEntitlementValidator.Config.fromEnvironment(environment) {
                return StripeEntitlementProvider(
                    store: store,
                    remoteValidator: StripeEntitlementValidator(config: config)
                )
            }
            return StripeEntitlementProvider(store: store)
        }
    }
}
