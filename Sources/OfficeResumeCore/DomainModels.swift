import Foundation

public enum OfficeApp: String, Codable, CaseIterable {
    case word
    case excel
    case powerpoint
    case outlook
    case onenote
}

public struct DocumentSnapshot: Codable, Hashable {
    public let app: OfficeApp
    public let displayName: String
    public let canonicalPath: String?
    public let isSaved: Bool
    public let isTempArtifact: Bool
    public let capturedAt: Date

    public init(
        app: OfficeApp,
        displayName: String,
        canonicalPath: String?,
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

    private enum CodingKeys: String, CodingKey {
        case app
        case displayName
        case canonicalPath
        case isSaved
        case isTempArtifact
        case capturedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decode(OfficeApp.self, forKey: .app)
        displayName = try container.decode(String.self, forKey: .displayName)
        canonicalPath = Self.normalizedPath(try container.decodeIfPresent(String.self, forKey: .canonicalPath))
        isSaved = try container.decode(Bool.self, forKey: .isSaved)
        isTempArtifact = try container.decode(Bool.self, forKey: .isTempArtifact)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(Self.normalizedPath(canonicalPath), forKey: .canonicalPath)
        try container.encode(isSaved, forKey: .isSaved)
        try container.encode(isTempArtifact, forKey: .isTempArtifact)
        try container.encode(capturedAt, forKey: .capturedAt)
    }

    private static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        switch trimmed.lowercased() {
        case "missing value", "missing", "null", "(null)", "<null>":
            return nil
        default:
            return trimmed
        }
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

    public init(
        app: OfficeApp,
        launchInstanceID: String,
        capturedAt: Date,
        documents: [DocumentSnapshot],
        windowsMeta: [WindowMetadata]
    ) {
        self.app = app
        self.launchInstanceID = launchInstanceID
        self.capturedAt = capturedAt
        self.documents = documents
        self.windowsMeta = windowsMeta
    }
}

public enum LifecycleEventType: String, Codable {
    case appLaunched
    case appTerminated
    case stateCaptured
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

public struct EntitlementState: Codable, Equatable {
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

public struct AccountState: Codable, Equatable {
    public struct BillingAction: Codable, Equatable {
        public enum Kind: String, Codable {
            case subscribe
            case manageSubscription
        }

        public let kind: Kind
        public let title: String

        public init(kind: Kind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    public let email: String?
    public let entitlement: EntitlementState
    public let billingAction: BillingAction?
    public let statusMessage: String?
    public let canSignIn: Bool
    public let canSignOut: Bool

    public init(
        email: String?,
        entitlement: EntitlementState,
        billingAction: BillingAction?,
        statusMessage: String?,
        canSignIn: Bool,
        canSignOut: Bool
    ) {
        self.email = email
        self.entitlement = entitlement
        self.billingAction = billingAction
        self.statusMessage = statusMessage
        self.canSignIn = canSignIn
        self.canSignOut = canSignOut
    }
}
