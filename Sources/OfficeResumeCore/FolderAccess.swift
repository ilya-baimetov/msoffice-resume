import Foundation

public struct FolderAccessGrant: Codable, Hashable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let bookmarkData: Data
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        displayName: String,
        rootPath: String,
        bookmarkData: Data,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct FolderAccessSession {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    public func end() {
        for url in urls.reversed() {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public actor FolderAccessStore {
    private struct State: Codable {
        var grants: [FolderAccessGrant]
    }

    private enum FileName {
        static let folderAccess = "folder-access-v1.json"
    }

    private let fileManager: FileManager
    private let baseDirectoryOverride: URL?
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectoryOverride
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func loadGrants() throws -> [FolderAccessGrant] {
        try loadState().grants.sorted { lhs, rhs in
            if lhs.rootPath.count == rhs.rootPath.count {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.rootPath.count > rhs.rootPath.count
        }
    }

    @discardableResult
    public func grantDirectories(_ directoryURLs: [URL], now: Date = Date()) throws -> [FolderAccessGrant] {
        var state = try loadState()
        var updatedByRootPath = Dictionary(uniqueKeysWithValues: state.grants.map { ($0.rootPath, $0) })
        var granted: [FolderAccessGrant] = []

        for directoryURL in directoryURLs {
            guard directoryURL.isFileURL else {
                continue
            }

            let normalizedRootPath = Self.normalizedPath(for: directoryURL)
            guard !normalizedRootPath.isEmpty else {
                continue
            }

            let bookmarkData = try directoryURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let existing = updatedByRootPath[normalizedRootPath]
            let grant = FolderAccessGrant(
                id: existing?.id ?? UUID().uuidString.lowercased(),
                displayName: directoryURL.lastPathComponent,
                rootPath: normalizedRootPath,
                bookmarkData: bookmarkData,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            updatedByRootPath[normalizedRootPath] = grant
            granted.append(grant)
        }

        state.grants = Array(updatedByRootPath.values)
        try saveState(state)
        return granted.sorted { $0.rootPath.count > $1.rootPath.count }
    }

    public func beginAccess(for documentPaths: [String]) throws -> FolderAccessSession {
        let normalizedDocumentPaths = Array(
            Set(
                documentPaths
                    .compactMap(Self.normalizedPath)
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedDocumentPaths.isEmpty else {
            return FolderAccessSession(urls: [])
        }

        let state = try loadState()
        let grants = state.grants
        var refreshedState = state
        var refreshed = false
        var startedURLs: [URL] = []
        var startedRootPaths: Set<String> = []

        for documentPath in normalizedDocumentPaths {
            guard let matchedGrant = Self.bestMatchingGrant(for: documentPath, in: grants) else {
                if suggestsProtectedLocation(for: documentPath) {
                    DebugLog.warning(
                        "No stored folder access grant matched restore path",
                        metadata: ["path": documentPath]
                    )
                }
                continue
            }
            guard startedRootPaths.insert(matchedGrant.rootPath).inserted else {
                continue
            }

            do {
                let resolved = try resolveGrant(matchedGrant)
                if let refreshedGrant = resolved.updatedGrant,
                   let index = refreshedState.grants.firstIndex(where: { $0.id == refreshedGrant.id }) {
                    refreshedState.grants[index] = refreshedGrant
                    refreshed = true
                }

                if resolved.url.startAccessingSecurityScopedResource() {
                    startedURLs.append(resolved.url)
                } else {
                    DebugLog.warning(
                        "Failed to start security-scoped access for folder grant",
                        metadata: [
                            "rootPath": matchedGrant.rootPath,
                            "displayName": matchedGrant.displayName,
                        ]
                    )
                }
            } catch {
                DebugLog.warning(
                    "Failed to resolve folder access grant",
                    metadata: [
                        "rootPath": matchedGrant.rootPath,
                        "displayName": matchedGrant.displayName,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        if refreshed {
            try saveState(refreshedState)
        }

        return FolderAccessSession(urls: startedURLs)
    }

    private func suggestsProtectedLocation(for path: String) -> Bool {
        let normalizedPath = Self.normalizedPath(path)
        guard let homeDirectory = fileManager.homeDirectoryForCurrentUser.path.removingTrailingSlashIfNeeded else {
            return false
        }

        let protectedRoots = [
            "Documents",
            "Desktop",
            "Downloads",
            "Library/CloudStorage",
            "Library/Mobile Documents",
        ].map { "\(homeDirectory)/\($0)" }

        return protectedRoots.contains { root in
            Self.isPath(normalizedPath, withinRootPath: root)
        }
    }

    private func resolveGrant(_ grant: FolderAccessGrant) throws -> (url: URL, updatedGrant: FolderAccessGrant?) {
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: grant.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        let normalizedRootPath = Self.normalizedPath(for: resolvedURL)
        guard isStale || normalizedRootPath != grant.rootPath else {
            return (resolvedURL, nil)
        }

        let refreshedBookmarkData = try resolvedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let refreshedGrant = FolderAccessGrant(
            id: grant.id,
            displayName: resolvedURL.lastPathComponent,
            rootPath: normalizedRootPath,
            bookmarkData: refreshedBookmarkData,
            createdAt: grant.createdAt,
            updatedAt: Date()
        )
        return (resolvedURL, refreshedGrant)
    }

    private func loadState() throws -> State {
        let fileURL = try fileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return State(grants: [])
        }

        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return State(grants: [])
        }

        return try decoder.decode(State.self, from: data)
    }

    private func saveState(_ state: State) throws {
        let fileURL = try fileURL()
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private func fileURL() throws -> URL {
        let baseDirectory: URL
        if let baseDirectoryOverride {
            baseDirectory = baseDirectoryOverride
        } else {
            baseDirectory = try RuntimeConfiguration.sharedRoot(
                fileManager: fileManager,
                environment: environment
            )
        }

        return baseDirectory
            .appendingPathComponent("restore", isDirectory: true)
            .appendingPathComponent(FileName.folderAccess)
    }

    static func bestMatchingGrant(for documentPath: String, in grants: [FolderAccessGrant]) -> FolderAccessGrant? {
        let normalizedDocumentPath = normalizedPath(documentPath)
        return grants
            .filter { isPath(normalizedDocumentPath, withinRootPath: $0.rootPath) }
            .max { lhs, rhs in
                normalizedPath(lhs.rootPath).count < normalizedPath(rhs.rootPath).count
            }
    }

    static func isPath(_ path: String, withinRootPath rootPath: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: normalizedPath(path)).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: normalizedPath(rootPath), isDirectory: true).standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else {
            return false
        }

        return zip(rootComponents, pathComponents).allSatisfy(==)
    }

    static func normalizedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path.removingTrailingSlashIfNeeded ?? trimmed
    }

    private static func normalizedPath(for directoryURL: URL) -> String {
        directoryURL.standardizedFileURL.path.removingTrailingSlashIfNeeded ?? directoryURL.path
    }
}

private extension String {
    var removingTrailingSlashIfNeeded: String? {
        guard !isEmpty else {
            return nil
        }
        if count > 1, hasSuffix("/") {
            return String(dropLast())
        }
        return self
    }
}
