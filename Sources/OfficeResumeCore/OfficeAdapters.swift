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

public final class AppleScriptOfficeAdapter: OfficeAdapter {
    public let app: OfficeApp
    private let scriptExecutor: ScriptExecuting
    private let snapshotStore: SnapshotStore?
    private let fileManager: FileManager
    private let cloudStorageRootsProvider: () -> [URL]

    public init(
        app: OfficeApp,
        scriptExecutor: ScriptExecuting = NSAppleScriptExecutor(),
        snapshotStore: SnapshotStore? = nil,
        fileManager: FileManager = .default,
        cloudStorageRootsProvider: (() -> [URL])? = nil
    ) {
        self.app = app
        self.scriptExecutor = scriptExecutor
        self.snapshotStore = snapshotStore
        self.fileManager = fileManager
        self.cloudStorageRootsProvider = cloudStorageRootsProvider ?? {
            Self.defaultCloudStorageRoots(fileManager: fileManager)
        }
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
                windowsMeta: []
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
                windowsMeta: []
            )

        case .outlook:
            let response = try scriptExecutor.run(script: fetchOutlookWindowsScript())
            let windowsMeta = parseWindowLines(response: response)
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: [],
                windowsMeta: windowsMeta
            )

        case .onenote:
            return AppSnapshot(
                app: app,
                launchInstanceID: launchID,
                capturedAt: capturedAt,
                documents: [],
                windowsMeta: []
            )
        }
    }

    public func restore(snapshot: AppSnapshot) async throws -> RestoreResult {
        switch app {
        case .word, .excel, .powerpoint:
            var restoredPaths: [String] = []
            var failedPaths: [String] = []

            if let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) {
                _ = try? scriptExecutor.run(script: "tell application id \"\(bundleID)\" to activate")
                try await waitUntilApplicationReady(bundleID: bundleID)
            }

            for doc in snapshot.documents {
                let path = normalizePathField(doc.canonicalPath)
                guard isRestorablePath(path) else {
                    continue
                }

                let candidatePaths = restorePathCandidates(for: path)
                var restored = false
                var lastError: Error?
                do {
                    for candidatePath in candidatePaths {
                        do {
                            try await openDocumentWithRetry(path: candidatePath, app: app)
                            restoredPaths.append(candidatePath)
                            restored = true
                            if candidatePath != path {
                                DebugLog.debug(
                                    "Resolved cloud path to local path for restore",
                                    metadata: [
                                        "app": app.rawValue,
                                        "sourcePath": path,
                                        "resolvedPath": candidatePath,
                                    ]
                                )
                            }
                            break
                        } catch {
                            lastError = error
                        }
                    }
                }

                if !restored {
                    failedPaths.append(path)
                    DebugLog.warning(
                        "Document restore open failed",
                        metadata: [
                            "app": app.rawValue,
                            "path": path,
                            "error": (lastError as NSError?)?.localizedDescription ?? "Unknown restore error",
                        ]
                    )
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
        guard OfficeBundleRegistry.documentRestoreApps.contains(app) else {
            return []
        }
        guard let snapshotStore else {
            return []
        }

        let unsavedEntries = state.documents.enumerated().filter { _, document in
            let normalizedPath = normalizePathField(document.canonicalPath)
            return !document.isSaved || (normalizedPath.isEmpty && looksUntitledDocument(named: document.displayName))
        }
        guard !unsavedEntries.isEmpty else {
            return []
        }

        let unsavedDirectory = try await snapshotStore.ensureUnsavedDirectory(for: app)
        var index = try await snapshotStore.loadUnsavedIndex(for: app)
        var artifacts: [DocumentSnapshot] = []

        for (documentIndex, document) in unsavedEntries {
            let artifactID = UUID().uuidString.lowercased()
            let extensionName = defaultExtension(for: app)
            let artifactURL = unsavedDirectory.appendingPathComponent("\(artifactID).\(extensionName)")

            do {
                _ = try scriptExecutor.run(
                    script: forceSaveDocumentScript(
                        for: app,
                        documentIndex: documentIndex + 1,
                        targetPath: artifactURL.path
                    )
                )
            } catch {
                continue
            }

            guard fileManager.fileExists(atPath: artifactURL.path) else {
                continue
            }

            let now = Date()
            let record = UnsavedArtifactRecord(
                artifactID: artifactID,
                originApp: app,
                originLaunchInstanceID: state.launchInstanceID,
                originalDisplayName: document.displayName,
                artifactPath: artifactURL.path,
                createdAt: now,
                updatedAt: now,
                lastReferencedSnapshotLaunchID: state.launchInstanceID
            )
            index.artifacts[artifactID] = record

            artifacts.append(
                DocumentSnapshot(
                    app: app,
                    displayName: document.displayName,
                    canonicalPath: artifactURL.path,
                    isSaved: true,
                    isTempArtifact: true,
                    capturedAt: now
                )
            )
        }

        if !artifacts.isEmpty {
            try await snapshotStore.saveUnsavedIndex(index, for: app)
        }

        return artifacts
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

            let name = normalizeTextField(fields[0])
            let path = normalizePathField(fields[1])
            let savedField = normalizeTextField(fields[2]).lowercased()
            let isSaved: Bool
            switch savedField {
            case "false", "no", "0":
                isSaved = false
            case "true", "yes", "1":
                isSaved = true
            default:
                isSaved = true
            }

            let displayName = name.isEmpty ? fallbackDisplayName(for: path) : name
            if displayName.isEmpty && path.isEmpty {
                continue
            }

            let snapshot = DocumentSnapshot(
                app: app,
                displayName: displayName,
                canonicalPath: path.isEmpty ? nil : path,
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
        set __or_output_lines to {}
        tell application id "\(bundleID)"
            set __or_docs to {}
            try
                set __or_docs to \(collectionName) as list
            end try

            repeat with __or_doc in __or_docs
                set __or_name to ""
                set __or_path to ""
                set __or_saved to "true"
                set __or_path_value to missing value

                try
                    set __or_name to (name of __or_doc) as string
                end try

                try
                    set __or_path_value to (full name of __or_doc)
                on error
                    try
                        set __or_path_value to (path of __or_doc)
                    end try
                end try

                if __or_path_value is not missing value then
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

                try
                    set __or_saved_value to (saved of __or_doc)
                    if __or_saved_value is false then
                        set __or_saved to "false"
                    else
                        set __or_saved to "true"
                    end if
                end try

                set end of __or_output_lines to (__or_name & "\t" & __or_path & "\t" & __or_saved)
            end repeat
        end tell

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
            // PowerPoint rejects `open location` for OneDrive `d.docs.live.net` links;
            // `open "<url>"` is accepted and also works for other Office URL documents.
            return "tell application id \"\(bundleID)\" to open \"\(escapedPath)\""
        }
        return "tell application id \"\(bundleID)\" to open POSIX file \"\(escapedPath)\""
    }

    private func restorePathCandidates(for path: String) -> [String] {
        var ordered: [String] = []

        if let localPath = resolveDocsLiveURLToLocalPath(path), isRestorablePath(localPath) {
            ordered.append(localPath)
        }

        ordered.append(path)

        var seen: Set<String> = []
        return ordered.filter { seen.insert($0).inserted }
    }

    private func resolveDocsLiveURLToLocalPath(_ path: String) -> String? {
        guard let url = URL(string: path),
              let host = url.host?.lowercased(),
              host == "d.docs.live.net"
        else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard components.count >= 2 else {
            return nil
        }

        // docs.live.net/<cid>/<relative path...>
        let relativeComponents = components.dropFirst()
        let decodedComponents = relativeComponents.map { component in
            component.removingPercentEncoding ?? component
        }
        let relativePath = decodedComponents.joined(separator: "/")

        for root in cloudStorageRootsProvider() {
            let candidate = root.appendingPathComponent(relativePath).path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func forceSaveDocumentScript(for app: OfficeApp, documentIndex: Int, targetPath: String) -> String {
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

        let escapedTargetPath = targetPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        tell application id "\(bundleID)"
            set __or_docs to \(collectionName)
            if (count of __or_docs) < \(documentIndex) then
                return "missing"
            end if

            set __or_doc to item \(documentIndex) of __or_docs
            set __or_saved_flag to true
            try
                set __or_saved_flag to (saved of __or_doc)
            end try

            if __or_saved_flag is true then
                return "already-saved"
            end if

            save __or_doc in (POSIX file "\(escapedTargetPath)")
            return "saved"
        end tell
        """
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

    private func normalizeTextField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == "missing value" || lowered == "missing" || lowered == "null" || lowered == "(null)" || lowered == "<null>" {
            return ""
        }
        return trimmed
    }

    private func normalizePathField(_ value: String?) -> String {
        normalizeTextField(value ?? "")
    }

    private func fallbackDisplayName(for path: String) -> String {
        guard !path.isEmpty else {
            return ""
        }
        return (path as NSString).lastPathComponent
    }

    private func looksUntitledDocument(named name: String) -> Bool {
        let lowered = normalizeTextField(name).lowercased()
        return lowered.hasPrefix("untitled")
            || lowered.hasPrefix("document")
            || lowered.hasPrefix("book")
            || lowered.hasPrefix("presentation")
            || lowered.hasPrefix("workbook")
    }

    private func isRestorablePath(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        let lowered = path.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || path.hasPrefix("/")
    }

    private func openDocumentWithRetry(
        path: String,
        app: OfficeApp,
        maxAttempts: Int = 10,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) async throws {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                _ = try scriptExecutor.run(script: openDocumentScript(path: path, app: app))
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts - 1 else {
                    break
                }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        if let lastError {
            throw lastError
        }
        throw OfficeAdapterError.scriptExecutionFailed
    }

    private func waitUntilApplicationReady(
        bundleID: String,
        maxAttempts: Int = 20,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) async throws {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                _ = try scriptExecutor.run(script: readinessProbeScript(bundleID: bundleID))
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts - 1 else {
                    break
                }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        if let lastError {
            throw lastError
        }
        throw OfficeAdapterError.scriptExecutionFailed
    }

    private func readinessProbeScript(bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to get name"
    }

    private static func defaultCloudStorageRoots(fileManager: FileManager) -> [URL] {
        var roots: [URL] = []

        let cloudStorageRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)

        if let entries = try? fileManager.contentsOfDirectory(
            at: cloudStorageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent.lowercased()
                if name.contains("onedrive") {
                    roots.append(entry)
                }
            }
        }

        let legacyOneDrive = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("OneDrive", isDirectory: true)
        if fileManager.fileExists(atPath: legacyOneDrive.path) {
            roots.append(legacyOneDrive)
        }

        return roots
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
            windowsMeta: []
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
        return [
            .word: AppleScriptOfficeAdapter(app: .word, snapshotStore: snapshotStore),
            .excel: AppleScriptOfficeAdapter(app: .excel, snapshotStore: snapshotStore),
            .powerpoint: AppleScriptOfficeAdapter(app: .powerpoint, snapshotStore: snapshotStore),
            .outlook: AppleScriptOfficeAdapter(app: .outlook, snapshotStore: nil),
            .onenote: OneNoteUnsupportedAdapter(),
        ]
    }
}
