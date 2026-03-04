import XCTest
@testable import OfficeResumeCore

final class OfficeResumeCoreTests: XCTestCase {
    func testPollingIntervalMappingsAndLabels() {
        XCTAssertEqual(PollingInterval.oneSecond.seconds, 1)
        XCTAssertEqual(PollingInterval.fiveSeconds.seconds, 5)
        XCTAssertEqual(PollingInterval.fifteenSeconds.seconds, 15)
        XCTAssertEqual(PollingInterval.oneMinute.seconds, 60)
        XCTAssertNil(PollingInterval.none.seconds)

        XCTAssertEqual(PollingInterval.oneSecond.displayName, "1s")
        XCTAssertEqual(PollingInterval.fiveSeconds.displayName, "5s")
        XCTAssertEqual(PollingInterval.fifteenSeconds.displayName, "15s")
        XCTAssertEqual(PollingInterval.oneMinute.displayName, "1m")
        XCTAssertEqual(PollingInterval.none.displayName, "None")
    }

    func testDocumentSnapshotRoundTrip() throws {
        let snapshot = DocumentSnapshot(
            app: .word,
            displayName: "resume.docx",
            canonicalPath: "/tmp/resume.docx",
            isSaved: true,
            isTempArtifact: false,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DocumentSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    func testRestoreEngineDedupeAndOneShotMarker() async throws {
        let tempRoot = makeTempDirectory(name: "restore-engine")
        let snapshotStore = FileSnapshotStore(channel: .direct, baseDirectoryOverride: tempRoot)
        let markerURL = tempRoot.appendingPathComponent("restore-markers.json")
        let markerStore = try FileRestoreMarkerStore(markerFileURL: markerURL)
        let engine = RestoreEngine(snapshotStore: snapshotStore, markerStore: markerStore)

        let snapshot = AppSnapshot(
            app: .word,
            launchInstanceID: "previous-launch",
            capturedAt: Date(),
            documents: [
                makeDocument(path: "/tmp/a.docx"),
                makeDocument(path: "/tmp/b.docx"),
                makeDocument(path: "/tmp/b.docx"),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )
        try await snapshotStore.saveSnapshot(snapshot)

        let currentDocs = [makeDocument(path: "/tmp/a.docx")]
        let launchID = "pid-1234"

        let plan = try await engine.buildPlan(
            for: .word,
            launchInstanceID: launchID,
            currentlyOpenDocuments: currentDocs
        )

        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.documentsToOpen.map(\.canonicalPath), ["/tmp/b.docx"])

        try await engine.markRestoreCompleted(app: .word, launchInstanceID: launchID)

        let secondPlan = try await engine.buildPlan(
            for: .word,
            launchInstanceID: launchID,
            currentlyOpenDocuments: currentDocs
        )
        XCTAssertNil(secondPlan)
    }

    func testFileSnapshotStoreRoundTripAndEvents() async throws {
        let tempRoot = makeTempDirectory(name: "snapshot-store")
        let store = FileSnapshotStore(channel: .direct, baseDirectoryOverride: tempRoot)

        let snapshot = AppSnapshot(
            app: .excel,
            launchInstanceID: "launch-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            documents: [makeDocument(path: "/tmp/sheet.xlsx", app: .excel)],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        try await store.saveSnapshot(snapshot)
        let loaded = try await store.loadSnapshot(for: .excel)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.documents.count, 1)
        XCTAssertEqual(loaded?.documents.first?.canonicalPath, "/tmp/sheet.xlsx")

        try await store.appendEvent(
            LifecycleEvent(app: .excel, type: .statePolled, timestamp: Date(), details: ["documents": "1"])
        )
        let recent = try await store.recentEvents(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.app, .excel)
    }

    func testUnsavedArtifactPurgeRemovesUnreferencedFiles() async throws {
        let tempRoot = makeTempDirectory(name: "artifact-purge")
        let store = FileSnapshotStore(channel: .direct, baseDirectoryOverride: tempRoot)
        let unsavedDirectory = try await store.ensureUnsavedDirectory(for: .word)

        let artifactURL = unsavedDirectory.appendingPathComponent("artifact.docx")
        try Data("temp".utf8).write(to: artifactURL)

        let now = Date()
        let record = UnsavedArtifactRecord(
            artifactID: "artifact-1",
            originApp: .word,
            originLaunchInstanceID: "launch",
            originalDisplayName: "Untitled",
            artifactPath: artifactURL.path,
            createdAt: now,
            updatedAt: now,
            lastReferencedSnapshotLaunchID: "launch"
        )
        try await store.saveUnsavedIndex(UnsavedArtifactIndex(artifacts: [record.artifactID: record]), for: .word)

        try await store.purgeUnreferencedArtifacts(for: .word, referencedPaths: [])

        let index = try await store.loadUnsavedIndex(for: .word)
        XCTAssertTrue(index.artifacts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func testTrialEntitlementExpiresAfter14Days() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try EntitlementFileStore(baseDirectory: makeTempDirectory(name: "trial-entitlement"))
        let provider = makeIsolatedTrialProvider(store: store, now: { now })

        let initial = await provider.currentState()
        XCTAssertTrue(initial.isActive)
        XCTAssertEqual(initial.plan, .trial)

        now = now.addingTimeInterval(13 * 24 * 60 * 60)
        let stillActive = await provider.currentState()
        XCTAssertTrue(stillActive.isActive)

        now = now.addingTimeInterval(2 * 24 * 60 * 60)
        let expired = await provider.currentState()
        XCTAssertFalse(expired.isActive)
        XCTAssertEqual(expired.plan, .none)
    }

    func testOfflineGraceDisablesAfterSevenDays() async throws {
        let baseNow = Date(timeIntervalSince1970: 1_700_000_000)
        var now = baseNow

        let store = try EntitlementFileStore(baseDirectory: makeTempDirectory(name: "offline-grace"))
        let provider = makeIsolatedTrialProvider(store: store, now: { now })

        let cached = EntitlementState(
            isActive: true,
            plan: .monthly,
            validUntil: baseNow.addingTimeInterval(30 * 24 * 60 * 60),
            trialEndsAt: nil,
            lastValidatedAt: baseNow.addingTimeInterval(-6 * 24 * 60 * 60)
        )
        try await store.saveCachedState(cached)

        let withinGrace = await provider.currentState()
        XCTAssertTrue(withinGrace.isActive)

        now = baseNow.addingTimeInterval(2 * 24 * 60 * 60)
        let expiredGrace = await provider.currentState()
        XCTAssertFalse(expiredGrace.isActive)
    }

    func testEntitlementOverrideLocalModeForcesActive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = EntitlementOverrideEvaluator.overrideState(
            now: now,
            environment: ["OFFICE_RESUME_LOCAL_MODE": "1"]
        )

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.isActive, true)
        XCTAssertEqual(state?.plan, .yearly)
    }

    func testEntitlementOverrideByDeviceIDFromFile() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tempRoot = makeTempDirectory(name: "free-pass")
        let freePassURL = tempRoot.appendingPathComponent("free-pass-v1.json")

        let config = FreePassConfig(
            localModeEnabled: false,
            freePassDeviceIDs: ["tester-device"],
            freePassEmails: []
        )
        let payload = try JSONEncoder().encode(config)
        try payload.write(to: freePassURL)

        let state = EntitlementOverrideEvaluator.overrideState(
            now: now,
            environment: ["OFFICE_RESUME_DEVICE_ID": "tester-device"],
            freePassFileURL: freePassURL
        )

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.isActive, true)
        XCTAssertEqual(state?.plan, .yearly)
    }

    func testEntitlementOverrideByEmailEnvironment() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = EntitlementOverrideEvaluator.overrideState(
            now: now,
            environment: [
                "OFFICE_RESUME_USER_EMAIL": "vip@example.com",
                "OFFICE_RESUME_FREE_PASS_EMAILS": "vip@example.com,other@example.com",
            ]
        )

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.isActive, true)
        XCTAssertEqual(state?.plan, .yearly)
    }

    private func makeDocument(path: String, app: OfficeApp = .word) -> DocumentSnapshot {
        DocumentSnapshot(
            app: app,
            displayName: (path as NSString).lastPathComponent,
            canonicalPath: path,
            isSaved: true,
            isTempArtifact: false,
            capturedAt: Date()
        )
    }

    private func makeTempDirectory(name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeResumeTests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeIsolatedTrialProvider(
        store: EntitlementFileStore,
        now: @escaping () -> Date
    ) -> TrialEntitlementProvider {
        let isolatedConfigURL = makeTempDirectory(name: "isolated-free-pass")
            .appendingPathComponent("free-pass-v1.json")

        return TrialEntitlementProvider(
            store: store,
            now: now,
            overrideEnvironment: [:],
            overrideFreePassFileURL: isolatedConfigURL
        )
    }
}
