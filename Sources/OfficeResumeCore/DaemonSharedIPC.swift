import Foundation

public enum DaemonSharedIPC {
    public static let statusFileName = "daemon-status-v1.json"
    public static let pauseCommandName = Notification.Name("com.pragprod.msofficeresume.command.pause")
    public static let restoreCommandName = Notification.Name("com.pragprod.msofficeresume.command.restore-now")
    public static let clearSnapshotCommandName = Notification.Name("com.pragprod.msofficeresume.command.clear-snapshot")
    public static let pausedUserInfoKey = "paused"
    public static let appUserInfoKey = "app"

    public static func publishStatus(_ status: DaemonStatusDTO, fileManager: FileManager = .default) {
        guard
            let data = try? JSONEncoder().encode(status),
            let url = try? statusFileURL(fileManager: fileManager)
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    public static func loadStatus(fileManager: FileManager = .default) -> DaemonStatusDTO? {
        guard
            let url = try? statusFileURL(fileManager: fileManager),
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(DaemonStatusDTO.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    public static func clearStatus(fileManager: FileManager = .default) {
        guard
            let url = try? statusFileURL(fileManager: fileManager),
            fileManager.fileExists(atPath: url.path)
        else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    public static func postSetPaused(_ paused: Bool) {
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            pauseCommandName,
            object: nil,
            userInfo: [pausedUserInfoKey: paused],
            deliverImmediately: true
        )
    }

    public static func postRestoreNow(app: OfficeApp?) {
        var userInfo: [String: Any] = [:]
        if let app {
            userInfo[appUserInfoKey] = app.rawValue
        }

        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            restoreCommandName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    public static func postClearSnapshot(app: OfficeApp?) {
        var userInfo: [String: Any] = [:]
        if let app {
            userInfo[appUserInfoKey] = app.rawValue
        }

        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            clearSnapshotCommandName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    private static func statusFileURL(fileManager: FileManager) throws -> URL {
        let root = try RuntimeConfiguration.appGroupOrFallbackRoot(fileManager: fileManager)
        return root
            .appendingPathComponent("ipc", isDirectory: true)
            .appendingPathComponent(statusFileName)
    }
}
