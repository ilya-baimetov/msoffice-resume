import AppKit
import Foundation

public enum HelperLauncher {
    public static let helperBundleIdentifier = "com.pragprod.msofficeresume.helper"
    public static let helperAppName = "OfficeResumeHelper.app"

    public static func ensureHelperRunning(bundleIdentifier: String = helperBundleIdentifier) {
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
}
