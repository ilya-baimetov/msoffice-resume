import Foundation

public enum DistributionChannel: String, Codable {
    case mas
    case direct
}

public enum RuntimeConfigurationError: Error {
    case appGroupUnavailable
}

public enum RuntimeConfiguration {
    public static let bundlePrefix = "com.pragprod.msofficeresume"
    public static let appGroupIdentifier = "group.\(bundlePrefix)"
    private static let channelKey = "\(bundlePrefix).distribution-channel"
    private static let localStorageFallbackKey = "OFFICE_RESUME_ALLOW_LOCAL_STORAGE_FALLBACK"
    private static let debugEntitlementBypassKey = "OFFICE_RESUME_ENABLE_DEBUG_ENTITLEMENT_BYPASS"
    private static let debugEntitlementBypassDefaultsKey = "\(bundlePrefix).debug-entitlement-bypass-enabled"
    private static let directBackendBaseURLEnvKey = "OFFICE_RESUME_DIRECT_BACKEND_BASE_URL"

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    public static func sharedDefaultsOrStandard() -> UserDefaults {
        sharedDefaults() ?? .standard
    }

    public static func setDistributionChannel(_ channel: DistributionChannel, userDefaults: UserDefaults? = sharedDefaults()) {
        guard let userDefaults else {
            return
        }
        userDefaults.set(channel.rawValue, forKey: channelKey)
        userDefaults.synchronize()
    }

    public static func distributionChannel(
        userDefaults: UserDefaults? = sharedDefaults(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DistributionChannel {
        if let raw = environment["OFFICE_RESUME_DISTRIBUTION_CHANNEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let envChannel = DistributionChannel(rawValue: raw) {
            return envChannel
        }

        if let stored = userDefaults?.string(forKey: channelKey),
           let storedChannel = DistributionChannel(rawValue: stored) {
            return storedChannel
        }

#if BILLING_MAS
        return .mas
#elseif BILLING_DIRECT
        return .direct
#else
        return .direct
#endif
    }

    public static func storageChannel(
        for channel: DistributionChannel,
        appGroupIdentifier: String = appGroupIdentifier
    ) -> StorageChannel {
        _ = channel
        return .appGroupFirst(appGroupIdentifier: appGroupIdentifier)
    }

    public static func appGroupOrFallbackRoot(
        appGroupIdentifier: String = appGroupIdentifier,
        bundlePrefix: String = bundlePrefix,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if environment["XCTestConfigurationFilePath"] != nil {
            return try developmentFallbackRoot(fileManager: fileManager, bundlePrefix: bundlePrefix)
        }

        if let appGroupRoot = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupRoot
        }

        guard allowsLocalStorageFallback(environment: environment) else {
            throw RuntimeConfigurationError.appGroupUnavailable
        }

        return try developmentFallbackRoot(fileManager: fileManager, bundlePrefix: bundlePrefix)
    }

    public static func allowsLocalStorageFallback(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if isEnabled(environment[localStorageFallbackKey]) {
            return true
        }

#if DEBUG
        return true
#else
        return false
#endif
    }

    public static func isDebugEntitlementBypassEnabled(
        userDefaults: UserDefaults = sharedDefaultsOrStandard(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG
        if isEnabled(environment[debugEntitlementBypassKey]) {
            return true
        }
        return userDefaults.bool(forKey: debugEntitlementBypassDefaultsKey)
#else
        _ = userDefaults
        _ = environment
        return false
#endif
    }

    public static func setDebugEntitlementBypassEnabled(
        _ enabled: Bool,
        userDefaults: UserDefaults = sharedDefaultsOrStandard()
    ) {
#if DEBUG
        userDefaults.set(enabled, forKey: debugEntitlementBypassDefaultsKey)
        userDefaults.synchronize()
#else
        _ = enabled
        _ = userDefaults
#endif
    }

    public static func directBackendBaseURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let raw = environment[directBackendBaseURLEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }

        if let raw = bundle.object(forInfoDictionaryKey: "OfficeResumeDirectBackendBaseURL") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let url = URL(string: trimmed) {
                return url
            }
        }

        return nil
    }

    private static func developmentFallbackRoot(fileManager: FileManager, bundlePrefix: String) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return appSupport
            .appendingPathComponent(bundlePrefix, isDirectory: true)
    }

    private static func isEnabled(_ rawValue: String?) -> Bool {
        guard let rawValue else {
            return false
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
