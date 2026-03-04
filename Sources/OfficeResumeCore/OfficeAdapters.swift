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
            throw NSError(domain: "OfficeResumeAppleScript", code: 1, userInfo: errorDict as? [String: Any])
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
        tell application id "\(bundleID)"
            set outputLines to {}
            repeat with itemRef in \(collectionName)
                set itemName to ""
                set itemPath to ""
                set itemSaved to true
                try
                    set itemName to (name of itemRef as string)
                end try
                try
                    set itemSaved to (saved of itemRef as boolean)
                end try
                try
                    set itemPath to POSIX path of (full name of itemRef)
                on error
                    try
                        set itemPath to (full name of itemRef as string)
                    on error
                        set itemPath to ""
                    end try
                end try
                set end of outputLines to (itemName & "\t" & itemPath & "\t" & (itemSaved as string))
            end repeat
            set AppleScript's text item delimiters to linefeed
            set outputText to outputLines as string
            set AppleScript's text item delimiters to ""
            return outputText
        end tell
        """
    }

    private func fetchOutlookWindowsScript() -> String {
        """
        tell application id "com.microsoft.Outlook"
            set outputLines to {}
            repeat with windowRef in windows
                set windowID to ""
                set windowTitle to ""
                set windowBounds to ""
                set windowClass to ""
                try
                    set windowID to (id of windowRef as string)
                end try
                try
                    set windowTitle to (name of windowRef as string)
                end try
                try
                    set windowBounds to (bounds of windowRef as string)
                end try
                try
                    set windowClass to (class of windowRef as string)
                end try
                set end of outputLines to (windowID & "\t" & windowTitle & "\t" & windowBounds & "\t" & windowClass)
            end repeat
            set AppleScript's text item delimiters to linefeed
            set outputText to outputLines as string
            set AppleScript's text item delimiters to ""
            return outputText
        end tell
        """
    }

    private func openDocumentScript(path: String, app: OfficeApp) -> String {
        let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) ?? ""
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
