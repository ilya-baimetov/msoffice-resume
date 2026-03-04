import AppKit
import Foundation

public enum OfficeAdapterError: Error {
    case unsupported
    case scriptExecutionFailed
}

public protocol ScriptExecuting {
    func run(script: String) throws -> String
}

public struct NSAppleScriptExecutor: ScriptExecuting {
    public init() {}

    public func run(script: String) throws -> String {
        var errorDict: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            throw OfficeAdapterError.scriptExecutionFailed
        }

        let descriptor = scriptObject.executeAndReturnError(&errorDict)
        if let errorDict {
            let number = errorDict[NSAppleScript.errorNumber] as? Int ?? 1
            let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw NSError(
                domain: "OfficeResumeAppleScript",
                code: number,
                userInfo: [
                    NSLocalizedDescriptionKey: "AppleScript error \(number): \(message)",
                    "OfficeResumeAppleScriptDetails": errorDict,
                ]
            )
        }

        return descriptor.stringValue ?? ""
    }
}

public actor UnsavedArtifactManager {
    private let snapshotStore: SnapshotStore
    private let fileManager: FileManager

    public init(snapshotStore: SnapshotStore, fileManager: FileManager = .default) {
        self.snapshotStore = snapshotStore
        self.fileManager = fileManager
    }

    public func materializeArtifacts(for snapshot: AppSnapshot) async throws -> [DocumentSnapshot] {
        guard OfficeBundleRegistry.documentRestoreApps.contains(snapshot.app) else {
            return []
        }

        let unsavedDocs = snapshot.documents.filter { !$0.isSaved || $0.canonicalPath.isEmpty }
        guard !unsavedDocs.isEmpty else {
            return []
        }

        let unsavedDirectory = try await snapshotStore.ensureUnsavedDirectory(for: snapshot.app)
        var index = try await snapshotStore.loadUnsavedIndex(for: snapshot.app)
        var output: [DocumentSnapshot] = []

        for doc in unsavedDocs {
            let artifactID = UUID().uuidString
            let extensionName = defaultExtension(for: snapshot.app)
            let fileName = "\(artifactID).\(extensionName)"
            let artifactURL = unsavedDirectory.appendingPathComponent(fileName)

            if !fileManager.fileExists(atPath: artifactURL.path) {
                try Data().write(to: artifactURL)
            }

            let now = Date()
            let record = UnsavedArtifactRecord(
                artifactID: artifactID,
                originApp: snapshot.app,
                originLaunchInstanceID: snapshot.launchInstanceID,
                originalDisplayName: doc.displayName,
                artifactPath: artifactURL.path,
                createdAt: now,
                updatedAt: now,
                lastReferencedSnapshotLaunchID: snapshot.launchInstanceID
            )
            index.artifacts[artifactID] = record

            let artifactDoc = DocumentSnapshot(
                app: snapshot.app,
                displayName: doc.displayName,
                canonicalPath: artifactURL.path,
                isSaved: true,
                isTempArtifact: true,
                capturedAt: now
            )
            output.append(artifactDoc)
        }

        try await snapshotStore.saveUnsavedIndex(index, for: snapshot.app)
        return output
    }

    private func defaultExtension(for app: OfficeApp) -> String {
        switch app {
        case .word:
            return "docx"
        case .excel:
            return "xlsx"
        case .powerpoint:
            return "pptx"
        default:
            return "tmp"
        }
    }
}

public final class AppleScriptOfficeAdapter: OfficeAdapter {
    public let app: OfficeApp
    private let scriptExecutor: ScriptExecuting
    private let artifactManager: UnsavedArtifactManager?

    public init(app: OfficeApp, scriptExecutor: ScriptExecuting = NSAppleScriptExecutor(), artifactManager: UnsavedArtifactManager? = nil) {
        self.app = app
        self.scriptExecutor = scriptExecutor
        self.artifactManager = artifactManager
    }

    public func fetchState() async throws -> AppSnapshot {
        let runningApp = currentRunningApplication()
        let launchID = launchInstanceID(for: runningApp)
        let capturedAt = Date()

        guard runningApp != nil else {
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: [],
                windowsMeta: [],
                restoreAttemptedForLaunch: false
            )
        }

        switch app {
        case .word, .excel, .powerpoint:
            let response = try scriptExecutor.run(script: fetchDocumentScript(for: app))
            let documents = parseDocumentLines(response: response, capturedAt: capturedAt)
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: documents,
                windowsMeta: [],
                restoreAttemptedForLaunch: false
            )

        case .outlook:
            let response = try scriptExecutor.run(script: fetchOutlookWindowsScript())
            let windowsMeta = parseWindowLines(response: response)
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: [],
                windowsMeta: windowsMeta,
                restoreAttemptedForLaunch: false
            )

        case .onenote:
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: [],
                windowsMeta: [],
                restoreAttemptedForLaunch: false
            )
        }
    }

    public func restore(snapshot: AppSnapshot) async throws -> RestoreResult {
        switch app {
        case .word, .excel, .powerpoint:
            var restoredPaths: [String] = []
            var failedPaths: [String] = []

            for doc in snapshot.documents {
                guard !doc.canonicalPath.isEmpty else {
                    continue
                }
                do {
                    _ = try scriptExecutor.run(script: openDocumentScript(path: doc.canonicalPath, app: app))
                    restoredPaths.append(doc.canonicalPath)
                } catch {
                    failedPaths.append(doc.canonicalPath)
                }
            }

            return RestoreResult(restoredPaths: restoredPaths, failedPaths: failedPaths)

        case .outlook:
            do {
                _ = try scriptExecutor.run(script: "tell application id \"com.microsoft.Outlook\" to activate")
            } catch {
                throw error
            }
            return RestoreResult(restoredPaths: [], failedPaths: [])

        case .onenote:
            throw OfficeAdapterError.unsupported
        }
    }

    public func forceSaveUntitled(state: AppSnapshot) async throws -> [DocumentSnapshot] {
        guard let artifactManager else {
            return []
        }
        return try await artifactManager.materializeArtifacts(for: state)
    }

    private func currentRunningApplication() -> NSRunningApplication? {
        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            return nil
        }

        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
    }

    private func launchInstanceID(for runningApp: NSRunningApplication?) -> String {
        guard let runningApp else {
            return "not-running"
        }

        let launchDate = runningApp.launchDate?.timeIntervalSince1970 ?? 0
        return "\(runningApp.processIdentifier)-\(Int64(launchDate))"
    }

    private func parseDocumentLines(response: String, capturedAt: Date) -> [DocumentSnapshot] {
        let lines = response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var documents: [DocumentSnapshot] = []

        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else {
                continue
            }

            let name = fields[0]
            let path = fields[1]
            let savedField = fields[2].lowercased()
            let isSaved = savedField == "true" || savedField == "yes"

            let snapshot = DocumentSnapshot(
                app: app,
                displayName: name,
                canonicalPath: path,
                isSaved: isSaved,
                isTempArtifact: false,
                capturedAt: capturedAt
            )
            documents.append(snapshot)
        }

        return documents
    }

    private func parseWindowLines(response: String) -> [WindowMetadata] {
        response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return WindowMetadata(
                    id: fields.count > 0 ? fields[0] : nil,
                    title: fields.count > 1 ? fields[1] : nil,
                    bounds: fields.count > 2 ? fields[2] : nil,
                    rawClass: fields.count > 3 ? fields[3] : nil
                )
            }
    }

    private func fetchDocumentScript(for app: OfficeApp) -> String {
        let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) ?? ""
        let collectionName: String

        switch app {
        case .word:
            collectionName = "documents"
        case .excel:
            collectionName = "workbooks"
        case .powerpoint:
            collectionName = "presentations"
        default:
            collectionName = "documents"
        }

        return """
        set __or_names to {}
        set __or_paths to {}
        set __or_saved_flags to {}

        tell application id "\(bundleID)"
            try
                set __or_names to (name of \(collectionName)) as list
            end try
            try
                set __or_paths to (full name of \(collectionName)) as list
            end try
            try
                set __or_saved_flags to (saved of \(collectionName)) as list
            end try
        end tell

        set __or_output_lines to {}
        set __or_count to (count of __or_names)

        repeat with __or_index from 1 to __or_count
            set __or_name to ""
            set __or_path to ""
            set __or_saved to "true"

            try
                set __or_name to (item __or_index of __or_names) as string
            end try

            if __or_index <= (count of __or_paths) then
                set __or_path_value to item __or_index of __or_paths
                set __or_path_text to ""
                try
                    set __or_path_text to (__or_path_value as string)
                end try

                if (__or_path_text starts with "http://") or (__or_path_text starts with "https://") then
                    set __or_path to __or_path_text
                else
                    try
                        set __or_path to POSIX path of __or_path_value
                    on error
                        set __or_path to __or_path_text
                    end try
                end if
            end if

            if __or_index <= (count of __or_saved_flags) then
                try
                    set __or_saved to ((item __or_index of __or_saved_flags) as string)
                end try
            end if

            set end of __or_output_lines to (__or_name & "\t" & __or_path & "\t" & __or_saved)
        end repeat

        set AppleScript's text item delimiters to linefeed
        set __or_output_text to __or_output_lines as string
        set AppleScript's text item delimiters to ""
        return __or_output_text
        """
    }

    private func fetchOutlookWindowsScript() -> String {
        """
        set __or_window_refs to {}
        tell application id "com.microsoft.Outlook"
            try
                set __or_window_refs to every window
            end try
        end tell

        set __or_output_lines to {}
        repeat with __or_window in __or_window_refs
            set __or_window_id to ""
            set __or_window_title to ""
            set __or_window_bounds to ""
            set __or_window_class to ""

            tell application id "com.microsoft.Outlook"
                try
                    set __or_window_id to (id of __or_window as string)
                end try
                try
                    set __or_window_title to (name of __or_window as string)
                end try
                try
                    set __or_window_bounds to (bounds of __or_window as string)
                end try
                try
                    set __or_window_class to (class of __or_window as string)
                end try
            end tell

            set end of __or_output_lines to (__or_window_id & "\t" & __or_window_title & "\t" & __or_window_bounds & "\t" & __or_window_class)
        end repeat

        set AppleScript's text item delimiters to linefeed
        set __or_output_text to __or_output_lines as string
        set AppleScript's text item delimiters to ""
        return __or_output_text
        """
    }

    private func openDocumentScript(path: String, app: OfficeApp) -> String {
        let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) ?? ""
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let lowerPath = path.lowercased()
        if lowerPath.hasPrefix("http://") || lowerPath.hasPrefix("https://") {
            return "tell application id \"\(bundleID)\" to open location \"\(escapedPath)\""
        }
        return "tell application id \"\(bundleID)\" to open POSIX file \"\(escapedPath)\""
    }
}

public struct OneNoteUnsupportedAdapter: OfficeAdapter {
    public let app: OfficeApp = .onenote

    public init() {}

    public func fetchState() async throws -> AppSnapshot {
        AppSnapshot(
            app: .onenote,
            launchInstanceID: "unsupported",
            capturedAt: Date(),
            documents: [],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )
    }

    public func restore(snapshot: AppSnapshot) async throws -> RestoreResult {
        throw OfficeAdapterError.unsupported
    }

    public func forceSaveUntitled(state: AppSnapshot) async throws -> [DocumentSnapshot] {
        []
    }
}

public enum OfficeAdapterFactory {
    public static func makeDefaultAdapters(snapshotStore: SnapshotStore) -> [OfficeApp: OfficeAdapter] {
        let artifactManager = UnsavedArtifactManager(snapshotStore: snapshotStore)
        return [
            .word: AppleScriptOfficeAdapter(app: .word, artifactManager: artifactManager),
            .excel: AppleScriptOfficeAdapter(app: .excel, artifactManager: artifactManager),
            .powerpoint: AppleScriptOfficeAdapter(app: .powerpoint, artifactManager: artifactManager),
            .outlook: AppleScriptOfficeAdapter(app: .outlook, artifactManager: nil),
            .onenote: OneNoteUnsupportedAdapter(),
        ]
    }
}
