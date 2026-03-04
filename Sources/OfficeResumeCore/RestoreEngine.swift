import Foundation

public protocol RestoreMarkerStore {
    func hasAttemptedRestore(for app: OfficeApp, launchInstanceID: String) async throws -> Bool
    func markRestoreAttempted(for app: OfficeApp, launchInstanceID: String) async throws
    func clear(for app: OfficeApp?) async throws
}

public actor FileRestoreMarkerStore: RestoreMarkerStore {
    private struct MarkerState: Codable {
        var appToLaunchID: [OfficeApp: String]
    }

    private let fileManager: FileManager
    private let markerFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileManager: FileManager = .default, markerFileURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let markerFileURL {
            self.markerFileURL = markerFileURL
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let directory = appSupport
                .appendingPathComponent("com.pragprod.msofficeresume", isDirectory: true)
                .appendingPathComponent("restore", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            self.markerFileURL = directory.appendingPathComponent("restore-markers-v1.json")
        }
    }

    public func hasAttemptedRestore(for app: OfficeApp, launchInstanceID: String) async throws -> Bool {
        let state = try loadState()
        return state.appToLaunchID[app] == launchInstanceID
    }

    public func markRestoreAttempted(for app: OfficeApp, launchInstanceID: String) async throws {
        var state = try loadState()
        state.appToLaunchID[app] = launchInstanceID
        try saveState(state)
    }

    public func clear(for app: OfficeApp?) async throws {
        if let app {
            var state = try loadState()
            state.appToLaunchID.removeValue(forKey: app)
            try saveState(state)
            return
        }

        try saveState(MarkerState(appToLaunchID: [:]))
    }

    private func loadState() throws -> MarkerState {
        guard fileManager.fileExists(atPath: markerFileURL.path) else {
            return MarkerState(appToLaunchID: [:])
        }

        let data = try Data(contentsOf: markerFileURL)
        if data.isEmpty {
            return MarkerState(appToLaunchID: [:])
        }

        return try decoder.decode(MarkerState.self, from: data)
    }

    private func saveState(_ state: MarkerState) throws {
        let data = try encoder.encode(state)
        let directory = markerFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: markerFileURL, options: .atomic)
    }
}

public struct RestorePlan {
    public let app: OfficeApp
    public let launchInstanceID: String
    public let documentsToOpen: [DocumentSnapshot]

    public init(app: OfficeApp, launchInstanceID: String, documentsToOpen: [DocumentSnapshot]) {
        self.app = app
        self.launchInstanceID = launchInstanceID
        self.documentsToOpen = documentsToOpen
    }
}

public enum RestoreEngineError: Error {
    case snapshotMissing
}

public actor RestoreEngine {
    private let snapshotStore: SnapshotStore
    private let markerStore: RestoreMarkerStore

    public init(snapshotStore: SnapshotStore, markerStore: RestoreMarkerStore) {
        self.snapshotStore = snapshotStore
        self.markerStore = markerStore
    }

    public func buildPlan(
        for app: OfficeApp,
        launchInstanceID: String,
        currentlyOpenDocuments: [DocumentSnapshot]
    ) async throws -> RestorePlan? {
        if try await markerStore.hasAttemptedRestore(for: app, launchInstanceID: launchInstanceID) {
            return nil
        }

        guard let snapshot = try await snapshotStore.loadSnapshot(for: app) else {
            return nil
        }

        if app == .outlook {
            return RestorePlan(app: app, launchInstanceID: launchInstanceID, documentsToOpen: [])
        }

        let documents = dedupeDocuments(snapshot.documents, currentlyOpenDocuments: currentlyOpenDocuments)
        return RestorePlan(app: app, launchInstanceID: launchInstanceID, documentsToOpen: documents)
    }

    public func markRestoreCompleted(app: OfficeApp, launchInstanceID: String) async throws {
        try await markerStore.markRestoreAttempted(for: app, launchInstanceID: launchInstanceID)
    }

    public func clearMarkers(for app: OfficeApp?) async throws {
        try await markerStore.clear(for: app)
    }

    public func dedupeDocuments(
        _ snapshotDocuments: [DocumentSnapshot],
        currentlyOpenDocuments: [DocumentSnapshot]
    ) -> [DocumentSnapshot] {
        let openPaths = Set(currentlyOpenDocuments.map(\.canonicalPath))
        var seen: Set<String> = []
        var output: [DocumentSnapshot] = []

        for doc in snapshotDocuments {
            guard !doc.canonicalPath.isEmpty else {
                continue
            }
            guard !openPaths.contains(doc.canonicalPath) else {
                continue
            }
            if seen.insert(doc.canonicalPath).inserted {
                output.append(doc)
            }
        }

        return output
    }
}
