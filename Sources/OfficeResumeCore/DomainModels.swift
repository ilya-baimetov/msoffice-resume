import Foundation

public enum OfficeApp: String, Codable, CaseIterable {
    case word
    case excel
    case powerpoint
    case outlook
    case onenote
}

public enum PollingInterval: String, Codable, CaseIterable {
    case oneSecond
    case fiveSeconds
    case fifteenSeconds
    case oneMinute
    case none

    public var seconds: TimeInterval? {
        switch self {
        case .oneSecond:
            return 1
        case .fiveSeconds:
            return 5
        case .fifteenSeconds:
            return 15
        case .oneMinute:
            return 60
        case .none:
            return nil
        }
    }
}

public struct DocumentSnapshot: Codable, Hashable {
    public let app: OfficeApp
    public let displayName: String
    public let canonicalPath: String
    public let isSaved: Bool
    public let isTempArtifact: Bool
    public let capturedAt: Date

    public init(
        app: OfficeApp,
        displayName: String,
        canonicalPath: String,
        isSaved: Bool,
        isTempArtifact: Bool,
        capturedAt: Date
    ) {
        self.app = app
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.isSaved = isSaved
        self.isTempArtifact = isTempArtifact
        self.capturedAt = capturedAt
    }
}

public struct WindowMetadata: Codable, Hashable {
    public let id: String?
    public let title: String?
    public let bounds: String?
    public let rawClass: String?

    public init(id: String?, title: String?, bounds: String?, rawClass: String?) {
        self.id = id
        self.title = title
        self.bounds = bounds
        self.rawClass = rawClass
    }
}

public struct AppSnapshot: Codable {
    public let app: OfficeApp
    public let launchInstanceID: String
    public let capturedAt: Date
    public let documents: [DocumentSnapshot]
    public let windowsMeta: [WindowMetadata]
    public var restoreAttemptedForLaunch: Bool

    public init(
        app: OfficeApp,
        launchInstanceID: String,
        capturedAt: Date,
        documents: [DocumentSnapshot],
        windowsMeta: [WindowMetadata],
        restoreAttemptedForLaunch: Bool
    ) {
        self.app = app
        self.launchInstanceID = launchInstanceID
        self.capturedAt = capturedAt
        self.documents = documents
        self.windowsMeta = windowsMeta
        self.restoreAttemptedForLaunch = restoreAttemptedForLaunch
    }
}

public enum LifecycleEventType: String, Codable {
    case appLaunched
    case appTerminated
    case statePolled
    case restoreStarted
    case restoreSucceeded
    case restoreFailed
}

public struct LifecycleEvent: Codable {
    public let app: OfficeApp
    public let type: LifecycleEventType
    public let timestamp: Date
    public let details: [String: String]

    public init(app: OfficeApp, type: LifecycleEventType, timestamp: Date, details: [String: String]) {
        self.app = app
        self.type = type
        self.timestamp = timestamp
        self.details = details
    }
}

public struct RestoreResult: Codable {
    public let restoredPaths: [String]
    public let failedPaths: [String]

    public init(restoredPaths: [String], failedPaths: [String]) {
        self.restoredPaths = restoredPaths
        self.failedPaths = failedPaths
    }
}

public struct EntitlementState: Codable {
    public enum Plan: String, Codable {
        case trial
        case monthly
        case yearly
        case none
    }

    public let isActive: Bool
    public let plan: Plan
    public let validUntil: Date?
    public let trialEndsAt: Date?
    public let lastValidatedAt: Date?

    public init(
        isActive: Bool,
        plan: Plan,
        validUntil: Date?,
        trialEndsAt: Date?,
        lastValidatedAt: Date?
    ) {
        self.isActive = isActive
        self.plan = plan
        self.validUntil = validUntil
        self.trialEndsAt = trialEndsAt
        self.lastValidatedAt = lastValidatedAt
    }
}
