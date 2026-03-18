import Foundation

public enum DistributionChannel: String, Codable {
    case mas
    case direct
}

public enum RuntimeConfiguration {
    public static let bundlePrefix = "com.pragprod.msofficeresume"
    public static let sharedDefaultsSuiteName = "group.\(bundlePrefix)"
    private static let channelKey = "\(bundlePrefix).distribution-channel"
    private static let debugEntitlementBypassKey = "OFFICE_RESUME_ENABLE_DEBUG_ENTITLEMENT_BYPASS"
    private static let debugEntitlementBypassDefaultsKey = "\(bundlePrefix).debug-entitlement-bypass-enabled"
    private static let directBackendBaseURLEnvKey = "OFFICE_RESUME_DIRECT_BACKEND_BASE_URL"

    public static func sharedDefaults(
        suiteName: String = sharedDefaultsSuiteName,
        legacyDomainNames: [String]? = nil
    ) -> UserDefaults {
        guard let shared = UserDefaults(suiteName: suiteName) else {
            return .standard
        }

        migrateLegacyDefaultsIfNeeded(
            shared,
            suiteName: suiteName,
            legacyDomainNames: legacyDomainNames ?? defaultLegacyDefaultsDomainNames()
        )
        return shared
    }

    public static func sharedDefaultsOrStandard(
        suiteName: String = sharedDefaultsSuiteName,
        legacyDomainNames: [String]? = nil
    ) -> UserDefaults {
        sharedDefaults(suiteName: suiteName, legacyDomainNames: legacyDomainNames)
    }

    public static func setDistributionChannel(_ channel: DistributionChannel, userDefaults: UserDefaults = sharedDefaults()) {
        userDefaults.set(channel.rawValue, forKey: channelKey)
        userDefaults.synchronize()
    }

    public static func distributionChannel(
        userDefaults: UserDefaults = sharedDefaults(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DistributionChannel {
        if let raw = environment["OFFICE_RESUME_DISTRIBUTION_CHANNEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let envChannel = DistributionChannel(rawValue: raw) {
            return envChannel
        }

        if let stored = userDefaults.string(forKey: channelKey),
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
        bundlePrefix: String = bundlePrefix
    ) -> StorageChannel {
        _ = channel
        return .applicationSupport(bundlePrefix: bundlePrefix)
    }

    public static func sharedRoot(
        bundlePrefix: String = bundlePrefix,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        _ = environment
        return try applicationSupportRoot(fileManager: fileManager, bundlePrefix: bundlePrefix)
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

    private static func applicationSupportRoot(fileManager: FileManager, bundlePrefix: String) throws -> URL {
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

    private static func defaultLegacyDefaultsDomainNames(bundle: Bundle = .main) -> [String] {
        let candidates = [
            bundle.bundleIdentifier,
            bundlePrefix,
            "\(bundlePrefix).direct",
            "\(bundlePrefix).helper",
        ]

        var unique: [String] = []
        for candidate in candidates.compactMap({ $0 }) where !unique.contains(candidate) && candidate != sharedDefaultsSuiteName {
            unique.append(candidate)
        }
        return unique
    }

    private static func migrateLegacyDefaultsIfNeeded(
        _ shared: UserDefaults,
        suiteName: String,
        legacyDomainNames: [String]
    ) {
        let keys = [
            channelKey,
            debugEntitlementBypassDefaultsKey,
        ]

        var didChange = false
        for key in keys where shared.object(forKey: key) == nil {
            for domainName in legacyDomainNames where domainName != suiteName {
                guard let legacy = UserDefaults(suiteName: domainName),
                      let value = legacy.object(forKey: key)
                else {
                    continue
                }

                shared.set(value, forKey: key)
                didChange = true
                break
            }
        }

        if didChange {
            shared.synchronize()
        }
    }
}
