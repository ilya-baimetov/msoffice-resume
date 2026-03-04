import AppKit
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

public enum HelperLauncher {
    public static let helperBundleIdentifier = "com.pragprod.msofficeresume.helper"
    public static let helperAppName = "OfficeResumeHelper.app"

    public static func ensureHelperRunning(bundleIdentifier: String = helperBundleIdentifier) {
        registerLoginItemIfAvailable(bundleIdentifier: bundleIdentifier)

        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            return
        }

        guard let helperURL = resolveHelperURL(bundleIdentifier: bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, _ in }
    }

    public static func terminateHelperIfRunning(bundleIdentifier: String = helperBundleIdentifier) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else {
            return
        }

        for app in running {
            _ = app.terminate()
        }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if remaining.isEmpty {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            _ = app.forceTerminate()
        }
    }

    private static func resolveHelperURL(bundleIdentifier: String) -> URL? {
        if let fromLaunchServices = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return fromLaunchServices
        }

        if let fromSibling = siblingHelperURL() {
            return fromSibling
        }

        let applicationsPath = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let fromApplications = applicationsPath.appendingPathComponent(helperAppName, isDirectory: true)
        if FileManager.default.fileExists(atPath: fromApplications.path) {
            return fromApplications
        }

        return nil
    }

    private static func siblingHelperURL() -> URL? {
        guard let mainBundleURL = Bundle.main.bundleURL.standardizedFileURL as URL? else {
            return nil
        }

        let parent = mainBundleURL.deletingLastPathComponent()
        let candidate = parent.appendingPathComponent(helperAppName, isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    private static func registerLoginItemIfAvailable(bundleIdentifier: String) {
#if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            let service = SMAppService.loginItem(identifier: bundleIdentifier)
            if service.status == .enabled {
                return
            }
            do {
                try service.register()
            } catch {
                DebugLog.warning(
                    "Login item registration failed; falling back to manual helper launch",
                    metadata: [
                        "bundleIdentifier": bundleIdentifier,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
#endif
    }
}
