import Foundation
import Security
#if canImport(StoreKit)
import StoreKit
#endif

public protocol RemoteEntitlementValidating {
    func fetchCurrentEntitlement() async throws -> EntitlementState
}

public enum EntitlementError: LocalizedError {
    case inactive
    case backendNotConfigured
    case notSignedIn
    case invalidResponse
    case portalUnavailable
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .inactive:
            return "Entitlement is inactive."
        case .backendNotConfigured:
            return "Direct backend is not configured."
        case .notSignedIn:
            return "Sign in is required first."
        case .invalidResponse:
            return "Received an invalid response from the entitlement service."
        case .portalUnavailable:
            return "Billing is not available for this account yet."
        case .unsupported:
            return "This action is not supported in this channel."
        }
    }
}

public enum DebugEntitlementBypassEvaluator {
    public static func overrideState(
        now: Date,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EntitlementState? {
        guard RuntimeConfiguration.isDebugEntitlementBypassEnabled(
            userDefaults: userDefaults,
            environment: environment
        ) else {
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
    public static let offlineGraceDays = 7

    public static func inactiveState(lastValidatedAt: Date? = nil) -> EntitlementState {
        EntitlementState(
            isActive: false,
            plan: .none,
            validUntil: nil,
            trialEndsAt: nil,
            lastValidatedAt: lastValidatedAt
        )
    }

    public static func applyOfflineGrace(to state: EntitlementState, now: Date) -> EntitlementState {
        guard state.isActive else {
            return state
        }

        guard let lastValidatedAt = state.lastValidatedAt else {
            return inactiveState(lastValidatedAt: state.lastValidatedAt)
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
    private let fileManager: FileManager
    private let cacheURL: URL
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

    public func clearCachedState() async throws {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        try fileManager.removeItem(at: cacheURL)
    }

    private func write(data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public actor CachedEntitlementProvider: EntitlementProvider {
    private let store: EntitlementFileStore
    private let remoteValidator: RemoteEntitlementValidating?
    private let now: () -> Date
    private let overrideEnvironment: [String: String]
    private let userDefaults: UserDefaults

    public init(
        store: EntitlementFileStore,
        remoteValidator: RemoteEntitlementValidating? = nil,
        now: @escaping () -> Date = Date.init,
        overrideEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) {
        self.store = store
        self.remoteValidator = remoteValidator
        self.now = now
        self.overrideEnvironment = overrideEnvironment
        self.userDefaults = userDefaults
    }

    public func currentState() async -> EntitlementState {
        let now = now()

        if let override = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            userDefaults: userDefaults,
            environment: overrideEnvironment
        ) {
            return override
        }

        do {
            if let cached = try await store.loadCachedState() {
                return EntitlementPolicy.applyOfflineGrace(to: cached, now: now)
            }
        } catch {
            return EntitlementPolicy.inactiveState()
        }

        return EntitlementPolicy.inactiveState()
    }

    public func refresh() async throws -> EntitlementState {
        let now = now()

        if let override = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            userDefaults: userDefaults,
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
                throw error
            }
        }

        if let cached = try await store.loadCachedState() {
            return EntitlementPolicy.applyOfflineGrace(to: cached, now: now)
        }

        return EntitlementPolicy.inactiveState()
    }

    public func canRestore() async -> Bool {
        (await currentState()).isActive
    }

    public func canMonitor() async -> Bool {
        (await currentState()).isActive
    }
}

public actor StoreKitEntitlementProvider: EntitlementProvider {
    private let base: CachedEntitlementProvider

    public init(
        store: EntitlementFileStore,
        remoteValidator: RemoteEntitlementValidating? = nil,
        now: @escaping () -> Date = Date.init,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) {
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
        self.base = CachedEntitlementProvider(
            store: store,
            remoteValidator: resolvedValidator,
            now: now,
            userDefaults: userDefaults
        )
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
    private let base: CachedEntitlementProvider

    public init(
        store: EntitlementFileStore,
        remoteValidator: RemoteEntitlementValidating? = nil,
        now: @escaping () -> Date = Date.init,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) {
        self.base = CachedEntitlementProvider(
            store: store,
            remoteValidator: remoteValidator,
            now: now,
            userDefaults: userDefaults
        )
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

public struct DirectServiceConfiguration {
    public static let defaultCallbackScheme = "officeresume-direct"

    public let baseURL: URL
    public let callbackScheme: String

    public init(baseURL: URL, callbackScheme: String = defaultCallbackScheme) {
        self.baseURL = baseURL
        self.callbackScheme = callbackScheme
    }

    public static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DirectServiceConfiguration? {
        guard let baseURL = RuntimeConfiguration.directBackendBaseURL(bundle: bundle, environment: environment) else {
            return nil
        }

        let callbackScheme: String
        if let raw = bundle.object(forInfoDictionaryKey: "OfficeResumeDirectCallbackScheme") as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            callbackScheme = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            callbackScheme = defaultCallbackScheme
        }

        return DirectServiceConfiguration(
            baseURL: baseURL,
            callbackScheme: callbackScheme
        )
    }

    public var requestLinkURL: URL {
        baseURL.appendingPathComponent("auth/request-link")
    }

    public var verifyDebugTokenURL: URL {
        baseURL.appendingPathComponent("auth/verify")
    }

    public var currentEntitlementURL: URL {
        baseURL.appendingPathComponent("entitlements/current")
    }

    public var billingEntryURL: URL {
        baseURL.appendingPathComponent("billing/entry")
    }
}

public struct DirectSession: Codable, Equatable {
    public let email: String
    public let sessionToken: String

    public init(email: String, sessionToken: String) {
        self.email = email
        self.sessionToken = sessionToken
    }
}

public actor DirectSessionKeychainStore {
    private enum Constants {
        static let service = "com.pragprod.msofficeresume.direct.session"
        static let account = "current"
    }

    public init() {}

    public func load() throws -> DirectSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: Constants.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        let decoder = JSONDecoder()
        return try decoder.decode(DirectSession.self, from: data)
    }

    public func save(_ session: DirectSession) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: Constants.account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var createQuery = baseQuery
            createQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(retryStatus))
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: Constants.account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

public struct StripeEntitlementValidator: RemoteEntitlementValidating {
    private struct Response: Decodable {
        let isActive: Bool
        let plan: String
        let validUntil: Date?
        let trialEndsAt: Date?
    }

    private let config: DirectServiceConfiguration
    private let sessionStore: DirectSessionKeychainStore
    private let session: URLSession

    public init(
        config: DirectServiceConfiguration,
        sessionStore: DirectSessionKeychainStore,
        session: URLSession = .shared
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.session = session
    }

    public func fetchCurrentEntitlement() async throws -> EntitlementState {
        guard let directSession = try await sessionStore.load() else {
            throw EntitlementError.notSignedIn
        }

        var request = URLRequest(url: config.currentEntitlementURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(directSession.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw EntitlementError.invalidResponse
        }

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

public actor DirectAccountProvider: AccountProvider {
    private struct RequestLinkResponse: Decodable {
        let ok: Bool
        let debugToken: String?
        let message: String?
    }

    private struct VerifyResponse: Decodable {
        let ok: Bool
        let sessionToken: String
        let email: String
    }

    private struct BillingEntryResponse: Decodable {
        let kind: String
        let title: String
        let url: String
    }

    private let configuration: DirectServiceConfiguration?
    private let sessionStore: DirectSessionKeychainStore
    private let entitlementProvider: StripeEntitlementProvider
    private let entitlementStore: EntitlementFileStore
    private let session: URLSession

    public init(
        configuration: DirectServiceConfiguration?,
        sessionStore: DirectSessionKeychainStore,
        entitlementStore: EntitlementFileStore,
        session: URLSession = .shared,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.entitlementStore = entitlementStore
        self.session = session

        if let configuration {
            self.entitlementProvider = StripeEntitlementProvider(
                store: entitlementStore,
                remoteValidator: StripeEntitlementValidator(
                    config: configuration,
                    sessionStore: sessionStore,
                    session: session
                ),
                userDefaults: userDefaults
            )
        } else {
            self.entitlementProvider = StripeEntitlementProvider(
                store: entitlementStore,
                remoteValidator: nil,
                userDefaults: userDefaults
            )
        }
    }

    public func currentAccountState() async -> AccountState {
        let entitlement = await entitlementProvider.currentState()
        let storedSession = try? await sessionStore.load()
        return AccountState(
            email: storedSession?.email,
            entitlement: entitlement,
            billingAction: nil,
            statusMessage: configuration == nil ? "Direct backend is not configured." : nil,
            canSignIn: storedSession == nil,
            canSignOut: storedSession != nil
        )
    }

    public func refreshAccountState() async throws -> AccountState {
        let storedSession = try await sessionStore.load()

        let entitlement: EntitlementState
        if storedSession != nil || RuntimeConfiguration.isDebugEntitlementBypassEnabled() {
            entitlement = try await entitlementProvider.refresh()
        } else {
            entitlement = await entitlementProvider.currentState()
        }

        let billingAction: AccountState.BillingAction?
        if let storedSession, configuration != nil {
            billingAction = try await fetchBillingAction(for: storedSession)
        } else {
            billingAction = nil
        }

        return AccountState(
            email: storedSession?.email,
            entitlement: entitlement,
            billingAction: billingAction,
            statusMessage: configuration == nil ? "Direct backend is not configured." : nil,
            canSignIn: storedSession == nil,
            canSignOut: storedSession != nil
        )
    }

    public func requestSignInLink(email: String) async throws {
        guard let configuration else {
            throw EntitlementError.backendNotConfigured
        }

        var request = URLRequest(url: configuration.requestLinkURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw EntitlementError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(RequestLinkResponse.self, from: data)
        guard decoded.ok else {
            throw EntitlementError.invalidResponse
        }

#if DEBUG
        if let debugToken = decoded.debugToken {
            try await completeDebugTokenSignIn(debugToken)
        }
#endif
    }

    public func handleIncomingURL(_ url: URL) async throws -> Bool {
        guard let configuration else {
            return false
        }
        guard url.scheme == configuration.callbackScheme else {
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let action = components?.queryItems?.first(where: { $0.name == "action" })?.value,
           action == "billingRefresh" {
            return (try await sessionStore.load()) != nil
        }
        if let refresh = components?.queryItems?.first(where: { $0.name == "billingRefresh" })?.value,
           ["1", "true", "yes"].contains(refresh.lowercased()) {
            return (try await sessionStore.load()) != nil
        }
        let sessionToken = components?.queryItems?.first(where: { $0.name == "sessionToken" || $0.name == "session" })?.value
        let email = components?.queryItems?.first(where: { $0.name == "email" })?.value

        guard let sessionToken, let email, !sessionToken.isEmpty, !email.isEmpty else {
            return false
        }

        try await sessionStore.save(DirectSession(email: email, sessionToken: sessionToken))
        return true
    }

    public func billingActionURL() async throws -> URL? {
        guard let configuration else {
            throw EntitlementError.backendNotConfigured
        }
        guard let directSession = try await sessionStore.load() else {
            throw EntitlementError.notSignedIn
        }

        var request = URLRequest(url: configuration.billingEntryURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(directSession.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EntitlementError.invalidResponse
        }

        if httpResponse.statusCode == 204 {
            throw EntitlementError.portalUnavailable
        }

        guard httpResponse.statusCode == 200 else {
            throw EntitlementError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(BillingEntryResponse.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw EntitlementError.invalidResponse
        }
        return url
    }

    public func signOut() async throws {
        try await sessionStore.clear()
        try await entitlementStore.clearCachedState()
    }

#if DEBUG
    private func completeDebugTokenSignIn(_ token: String) async throws {
        guard let configuration else {
            throw EntitlementError.backendNotConfigured
        }

        var request = URLRequest(url: configuration.verifyDebugTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw EntitlementError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(VerifyResponse.self, from: data)
        try await sessionStore.save(DirectSession(email: decoded.email, sessionToken: decoded.sessionToken))
        _ = try await entitlementProvider.refresh()
    }
#endif

    private func fetchBillingAction(for directSession: DirectSession) async throws -> AccountState.BillingAction? {
        guard let configuration else {
            return nil
        }

        var request = URLRequest(url: configuration.billingEntryURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(directSession.sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EntitlementError.invalidResponse
        }

        if httpResponse.statusCode == 204 {
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            throw EntitlementError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(BillingEntryResponse.self, from: data)
        let kind: AccountState.BillingAction.Kind
        switch decoded.kind {
        case "subscribe":
            kind = .subscribe
        case "manageSubscription":
            kind = .manageSubscription
        default:
            throw EntitlementError.invalidResponse
        }

        return AccountState.BillingAction(kind: kind, title: decoded.title)
    }
}

public actor MASAccountProvider: AccountProvider {
    private let entitlementProvider: StoreKitEntitlementProvider
    private let manageSubscriptionURL = URL(string: "https://apps.apple.com/account/subscriptions")

    public init(
        entitlementStore: EntitlementFileStore,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) {
        self.entitlementProvider = StoreKitEntitlementProvider(
            store: entitlementStore,
            userDefaults: userDefaults
        )
    }

    public func currentAccountState() async -> AccountState {
        let entitlement = await entitlementProvider.currentState()
        return AccountState(
            email: nil,
            entitlement: entitlement,
            billingAction: AccountState.BillingAction(kind: .manageSubscription, title: "Manage Subscription"),
            statusMessage: nil,
            canSignIn: false,
            canSignOut: false
        )
    }

    public func refreshAccountState() async throws -> AccountState {
        let entitlement = try await entitlementProvider.refresh()
        return AccountState(
            email: nil,
            entitlement: entitlement,
            billingAction: AccountState.BillingAction(kind: .manageSubscription, title: "Manage Subscription"),
            statusMessage: nil,
            canSignIn: false,
            canSignOut: false
        )
    }

    public func requestSignInLink(email: String) async throws {
        _ = email
        throw EntitlementError.unsupported
    }

    public func handleIncomingURL(_ url: URL) async throws -> Bool {
        _ = url
        return false
    }

    public func billingActionURL() async throws -> URL? {
        manageSubscriptionURL
    }

    public func signOut() async throws {
        throw EntitlementError.unsupported
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
            return EntitlementPolicy.inactiveState(lastValidatedAt: Date())
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) -> EntitlementProvider {
        switch channel {
        case .mas:
            return StoreKitEntitlementProvider(store: store, userDefaults: userDefaults)
        case .direct:
            _ = environment
            return StripeEntitlementProvider(store: store, userDefaults: userDefaults)
        }
    }
}

public enum AccountProviderFactory {
    public static func makeProvider(
        channel: DistributionChannel,
        store: EntitlementFileStore,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = RuntimeConfiguration.sharedDefaultsOrStandard()
    ) -> AccountProvider {
        switch channel {
        case .mas:
            return MASAccountProvider(entitlementStore: store, userDefaults: userDefaults)
        case .direct:
            return DirectAccountProvider(
                configuration: DirectServiceConfiguration.resolve(bundle: bundle, environment: environment),
                sessionStore: DirectSessionKeychainStore(),
                entitlementStore: store,
                userDefaults: userDefaults
            )
        }
    }
}
