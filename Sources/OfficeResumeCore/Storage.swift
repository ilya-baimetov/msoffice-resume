import Foundation

public enum StorageChannel: Equatable {
    case applicationSupport(bundlePrefix: String)
}

public struct UnsavedArtifactRecord: Codable, Hashable {
    public let artifactID: String
    public let originApp: OfficeApp
    public let originLaunchInstanceID: String
    public let originalDisplayName: String
    public let artifactPath: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastReferencedSnapshotLaunchID: String

    public init(
        artifactID: String,
        originApp: OfficeApp,
        originLaunchInstanceID: String,
        originalDisplayName: String,
        artifactPath: String,
        createdAt: Date,
        updatedAt: Date,
        lastReferencedSnapshotLaunchID: String
    ) {
        self.artifactID = artifactID
        self.originApp = originApp
        self.originLaunchInstanceID = originLaunchInstanceID
        self.originalDisplayName = originalDisplayName
        self.artifactPath = artifactPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReferencedSnapshotLaunchID = lastReferencedSnapshotLaunchID
    }
}

public struct UnsavedArtifactIndex: Codable {
    public var artifacts: [String: UnsavedArtifactRecord]

    public init(artifacts: [String: UnsavedArtifactRecord] = [:]) {
        self.artifacts = artifacts
    }
}

public protocol SnapshotStore {
    func loadSnapshot(for app: OfficeApp) async throws -> AppSnapshot?
    func saveSnapshot(_ snapshot: AppSnapshot) async throws
    func clearSnapshot(for app: OfficeApp?) async throws
    func latestSnapshotCapturedAt() async throws -> [OfficeApp: Date]

    func appendEvent(_ event: LifecycleEvent) async throws
    func recentEvents(limit: Int) async throws -> [LifecycleEvent]

    func loadUnsavedIndex(for app: OfficeApp) async throws -> UnsavedArtifactIndex
    func saveUnsavedIndex(_ index: UnsavedArtifactIndex, for app: OfficeApp) async throws
    func ensureUnsavedDirectory(for app: OfficeApp) async throws -> URL
    func purgeUnreferencedArtifacts(for app: OfficeApp, referencedPaths: Set<String>) async throws
}

public actor FileSnapshotStore: SnapshotStore {
    private enum FileName {
        static let snapshot = "snapshot-v1.json"
        static let events = "events-v1.ndjson"
        static let unsavedIndex = "unsaved-index-v1.json"
        static let unsavedDirectory = "unsaved"
    }

    private let channel: StorageChannel
    private let baseDirectoryOverride: URL?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        channel: StorageChannel,
        fileManager: FileManager = .default,
        baseDirectoryOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.channel = channel
        self.baseDirectoryOverride = baseDirectoryOverride
        self.fileManager = fileManager
        self.environment = environment

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func loadSnapshot(for app: OfficeApp) async throws -> AppSnapshot? {
        let fileURL = try snapshotURL(for: app)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: AppSnapshot) async throws {
        let fileURL = try snapshotURL(for: snapshot.app)
        let data = try encoder.encode(snapshot)
        try write(data: data, to: fileURL)
    }

    public func clearSnapshot(for app: OfficeApp?) async throws {
        if let app {
            try clearAppState(for: app)
            return
        }

        for app in OfficeApp.allCases {
            try clearAppState(for: app)
        }
    }

    public func latestSnapshotCapturedAt() async throws -> [OfficeApp: Date] {
        var result: [OfficeApp: Date] = [:]
        for app in OfficeApp.allCases {
            if let snapshot = try await loadSnapshot(for: app) {
                result[app] = snapshot.capturedAt
            }
        }
        return result
    }

    public func appendEvent(_ event: LifecycleEvent) async throws {
        let fileURL = try eventsURL(for: event.app)
        let eventData = try encoder.encode(event)
        guard let line = String(data: eventData, encoding: .utf8) else {
            return
        }

        let payload = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try write(data: payload, to: fileURL)
        }
    }

    public func recentEvents(limit: Int) async throws -> [LifecycleEvent] {
        var allEvents: [LifecycleEvent] = []

        for app in OfficeApp.allCases {
            let fileURL = try eventsURL(for: app)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                continue
            }

            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            for line in lines {
                guard let lineData = line.data(using: .utf8) else {
                    continue
                }
                if let decoded = try? decoder.decode(LifecycleEvent.self, from: lineData) {
                    allEvents.append(decoded)
                }
            }
        }

        let sorted = allEvents.sorted(by: { $0.timestamp > $1.timestamp })
        return Array(sorted.prefix(max(0, limit)))
    }

    public func loadUnsavedIndex(for app: OfficeApp) async throws -> UnsavedArtifactIndex {
        let fileURL = try unsavedIndexURL(for: app)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return UnsavedArtifactIndex()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(UnsavedArtifactIndex.self, from: data)
    }

    public func saveUnsavedIndex(_ index: UnsavedArtifactIndex, for app: OfficeApp) async throws {
        let fileURL = try unsavedIndexURL(for: app)
        let data = try encoder.encode(index)
        try write(data: data, to: fileURL)
    }

    public func ensureUnsavedDirectory(for app: OfficeApp) async throws -> URL {
        let directory = try stateRoot(for: app).appendingPathComponent(FileName.unsavedDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func purgeUnreferencedArtifacts(for app: OfficeApp, referencedPaths: Set<String>) async throws {
        var index = try await loadUnsavedIndex(for: app)
        var updatedArtifacts = index.artifacts

        for (artifactID, record) in index.artifacts {
            let fileURL = URL(fileURLWithPath: record.artifactPath)
            let exists = fileManager.fileExists(atPath: fileURL.path)
            if !exists || !referencedPaths.contains(record.artifactPath) {
                if exists {
                    try? fileManager.removeItem(at: fileURL)
                }
                updatedArtifacts.removeValue(forKey: artifactID)
            }
        }

        index.artifacts = updatedArtifacts
        try await saveUnsavedIndex(index, for: app)
    }

    private func clearAppState(for app: OfficeApp) throws {
        let root = try stateRoot(for: app)

        let snapshotFile = root.appendingPathComponent(FileName.snapshot)
        if fileManager.fileExists(atPath: snapshotFile.path) {
            try fileManager.removeItem(at: snapshotFile)
        }

        let unsavedIndexFile = root.appendingPathComponent(FileName.unsavedIndex)
        if fileManager.fileExists(atPath: unsavedIndexFile.path) {
            try fileManager.removeItem(at: unsavedIndexFile)
        }

        let unsavedDirectory = root.appendingPathComponent(FileName.unsavedDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: unsavedDirectory.path) {
            try fileManager.removeItem(at: unsavedDirectory)
        }
    }

    private func snapshotURL(for app: OfficeApp) throws -> URL {
        try stateRoot(for: app).appendingPathComponent(FileName.snapshot)
    }

    private func eventsURL(for app: OfficeApp) throws -> URL {
        try stateRoot(for: app).appendingPathComponent(FileName.events)
    }

    private func unsavedIndexURL(for app: OfficeApp) throws -> URL {
        try stateRoot(for: app).appendingPathComponent(FileName.unsavedIndex)
    }

    private func stateRoot(for app: OfficeApp) throws -> URL {
        guard let bundleID = OfficeBundleRegistry.bundleIdentifier(for: app) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let base: URL
        if let baseDirectoryOverride {
            base = baseDirectoryOverride
        } else {
            switch channel {
            case let .applicationSupport(bundlePrefix):
                let root = try RuntimeConfiguration.sharedRoot(
                    bundlePrefix: RuntimeConfiguration.bundlePrefix,
                    fileManager: fileManager,
                    environment: environment
                )
                _ = bundlePrefix
                base = root.appendingPathComponent("state", isDirectory: true)
            }
        }

        let root = base
            .appendingPathComponent(bundleID, isDirectory: true)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
