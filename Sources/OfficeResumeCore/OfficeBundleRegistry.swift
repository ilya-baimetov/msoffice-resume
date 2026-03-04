import Foundation

public enum OfficeBundleRegistry {
    public static let bundleToApp: [String: OfficeApp] = [
        "com.microsoft.Word": .word,
        "com.microsoft.Excel": .excel,
        "com.microsoft.Powerpoint": .powerpoint,
        "com.microsoft.Outlook": .outlook,
        "com.microsoft.onenote.mac": .onenote,
    ]
    public static let appToBundle: [OfficeApp: String] = Dictionary(
        uniqueKeysWithValues: bundleToApp.map { ($0.value, $0.key) }
    )

    public static let documentRestoreApps: [OfficeApp] = [.word, .excel, .powerpoint]
    public static let lifecycleOnlyApps: [OfficeApp] = [.outlook]
    public static let unsupportedApps: [OfficeApp] = [.onenote]

    public static func app(for bundleIdentifier: String?) -> OfficeApp? {
        guard let bundleIdentifier else {
            return nil
        }
        return bundleToApp[bundleIdentifier]
    }

    public static func bundleIdentifier(for app: OfficeApp) -> String? {
        appToBundle[app]
    }
}
