import Foundation

public enum DistributionChannel: String, Codable {
    case mas
    case direct
}

public enum RuntimeConfiguration {
    public static let appGroupIdentifier = "group.com.pragprod.msofficeresume"
    private static let channelKey = "com.pragprod.msofficeresume.distribution-channel"

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
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
        switch channel {
        case .direct:
            return .direct
        case .mas:
            return .mas(appGroupIdentifier: appGroupIdentifier)
        }
    }
}

