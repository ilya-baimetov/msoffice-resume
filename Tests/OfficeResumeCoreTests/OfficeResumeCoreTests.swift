import XCTest
@testable import OfficeResumeCore

final class OfficeResumeCoreTests: XCTestCase {
    func testDaemonSharedIPCStatusRoundTrip() throws {
        let status = DaemonStatusDTO(
            isPaused: false,
            helperRunning: true,
            entitlementActive: true,
            entitlementPlan: .yearly,
            entitlementValidUntil: Date(timeIntervalSince1970: 1_800_000_000),
            entitlementTrialEndsAt: nil,
            accessibilityTrusted: true,
            latestSnapshotCapturedAt: [.word: Date(timeIntervalSince1970: 1_700_000_000)],
            unsupportedApps: [.onenote]
        )

        DaemonSharedIPC.publishStatus(status)
        defer { DaemonSharedIPC.clearStatus() }

        let loaded = DaemonSharedIPC.loadStatus()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.helperRunning, true)
        XCTAssertEqual(loaded?.accessibilityTrusted, true)
        XCTAssertEqual(loaded?.entitlementPlan, .yearly)
    }

    func testDaemonStatusRoundTripIncludesAccessibilityState() throws {
        let status = DaemonStatusDTO(
            isPaused: false,
            helperRunning: true,
            entitlementActive: true,
            entitlementPlan: .trial,
            entitlementValidUntil: Date(timeIntervalSince1970: 1_700_086_400),
            entitlementTrialEndsAt: Date(timeIntervalSince1970: 1_700_086_400),
            accessibilityTrusted: true,
            latestSnapshotCapturedAt: [.word: Date(timeIntervalSince1970: 1_700_000_000)],
            unsupportedApps: [.onenote]
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(DaemonStatusDTO.self, from: data)
        XCTAssertTrue(decoded.accessibilityTrusted)
        XCTAssertEqual(decoded.latestSnapshotCapturedAt[.word], status.latestSnapshotCapturedAt[.word])
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

    func testRestoreEngineIgnoresPlaceholderCanonicalPaths() async throws {
        let tempRoot = makeTempDirectory(name: "restore-engine-placeholder")
        let snapshotStore = FileSnapshotStore(channel: .direct, baseDirectoryOverride: tempRoot)
        let markerURL = tempRoot.appendingPathComponent("restore-markers.json")
        let markerStore = try FileRestoreMarkerStore(markerFileURL: markerURL)
        let engine = RestoreEngine(snapshotStore: snapshotStore, markerStore: markerStore)

        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "previous-launch",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Bad", canonicalPath: "missing value", isSaved: true, isTempArtifact: false, capturedAt: now),
                DocumentSnapshot(app: .powerpoint, displayName: "Deck", canonicalPath: " /tmp/demo.pptx ", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )
        try await snapshotStore.saveSnapshot(snapshot)

        let plan = try await engine.buildPlan(
            for: .powerpoint,
            launchInstanceID: "new-launch",
            currentlyOpenDocuments: []
        )

        XCTAssertEqual(plan?.documentsToOpen.map(\.canonicalPath), ["/tmp/demo.pptx"])
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
            LifecycleEvent(app: .excel, type: .stateCaptured, timestamp: Date(), details: ["documents": "1"])
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

    func testRuntimeConfigurationUsesStoredDirectChannel() {
        let suiteName = "OfficeResumeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("direct", forKey: "com.pragprod.msofficeresume.distribution-channel")

        let channel = RuntimeConfiguration.distributionChannel(userDefaults: defaults, environment: [:])
        XCTAssertEqual(channel, .direct)
        XCTAssertEqual(RuntimeConfiguration.storageChannel(for: channel), .direct)
    }

    func testForceSaveUntitledPersistsRealArtifactAndIndex() async throws {
        let tempRoot = makeTempDirectory(name: "force-save")
        let store = FileSnapshotStore(channel: .direct, baseDirectoryOverride: tempRoot)
        let executor = MockScriptExecutor { script in
            guard let path = Self.extractPath(fromSaveScript: script) else {
                return ""
            }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("artifact".utf8).write(to: url)
            return "saved"
        }

        let adapter = AppleScriptOfficeAdapter(
            app: .word,
            scriptExecutor: executor,
            snapshotStore: store
        )

        let state = AppSnapshot(
            app: .word,
            launchInstanceID: "launch-123",
            capturedAt: Date(),
            documents: [
                DocumentSnapshot(
                    app: .word,
                    displayName: "Untitled 1",
                    canonicalPath: "",
                    isSaved: false,
                    isTempArtifact: false,
                    capturedAt: Date()
                ),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        let artifacts = try await adapter.forceSaveUntitled(state: state)
        XCTAssertEqual(artifacts.count, 1)

        guard let artifactPath = artifacts.first?.canonicalPath else {
            XCTFail("Expected force-saved artifact path")
            return
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: artifactPath))
        XCTAssertEqual(String(data: payload, encoding: .utf8), "artifact")

        let index = try await store.loadUnsavedIndex(for: .word)
        XCTAssertEqual(index.artifacts.count, 1)
    }

    func testRestoreSkipsPlaceholderPathsAndNormalizesWhitespace() async throws {
        var executedScripts: [String] = []
        let executor = MockScriptExecutor { script in
            executedScripts.append(script)
            return "ok"
        }

        let adapter = AppleScriptOfficeAdapter(app: .powerpoint, scriptExecutor: executor, snapshotStore: nil)
        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-restore",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Bad", canonicalPath: "missing value", isSaved: true, isTempArtifact: false, capturedAt: now),
                DocumentSnapshot(app: .powerpoint, displayName: "Deck 1", canonicalPath: "  /tmp/deck1.pptx  ", isSaved: true, isTempArtifact: false, capturedAt: now),
                DocumentSnapshot(app: .powerpoint, displayName: "Deck 2", canonicalPath: "https://example.com/deck2.pptx", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/deck1.pptx", "https://example.com/deck2.pptx"])

        let openScripts = executedScripts.filter { $0.contains(" to open ") }
        XCTAssertEqual(openScripts.count, 2)
    }

    func testRestoreRetriesTransientOpenFailure() async throws {
        var openAttempts = 0
        let executor = MockScriptExecutor { script in
            if script.contains(" to open ") {
                openAttempts += 1
                if openAttempts < 3 {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "not ready"])
                }
            }
            return "ok"
        }

        let adapter = AppleScriptOfficeAdapter(app: .powerpoint, scriptExecutor: executor, snapshotStore: nil)
        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-retry",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Deck", canonicalPath: "/tmp/retry.pptx", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/retry.pptx"])
        XCTAssertEqual(openAttempts, 3)
    }

    func testPowerPointURLRestoreUsesOpenStringCommandWhenNoLocalMapping() async throws {
        var executedScripts: [String] = []
        let executor = MockScriptExecutor { script in
            executedScripts.append(script)
            return "ok"
        }

        let adapter = AppleScriptOfficeAdapter(
            app: .powerpoint,
            scriptExecutor: executor,
            snapshotStore: nil,
            cloudStorageRootsProvider: { [] }
        )
        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-url",
            capturedAt: now,
            documents: [
                DocumentSnapshot(
                    app: .powerpoint,
                    displayName: "Cloud Deck",
                    canonicalPath: "https://d.docs.live.net/1234/Deck.pptx",
                    isSaved: true,
                    isTempArtifact: false,
                    capturedAt: now
                ),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        _ = try await adapter.restore(snapshot: snapshot)
        guard let openScript = executedScripts.first(where: { $0.contains(" to open ") }) else {
            XCTFail("Expected an open script")
            return
        }
        XCTAssertTrue(openScript.contains(" to open \"https://d.docs.live.net/1234/Deck.pptx\""))
        XCTAssertFalse(openScript.contains("open location"))
    }

    func testPowerPointDocsLiveURLRestoreUsesLocalOneDrivePathWhenAvailable() async throws {
        var executedScripts: [String] = []
        let executor = MockScriptExecutor { script in
            executedScripts.append(script)
            return "ok"
        }

        let root = makeTempDirectory(name: "onedrive-root")
            .appendingPathComponent("OneDrive-Personal", isDirectory: true)
        let localDeck = root
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("Sber", isDirectory: true)
            .appendingPathComponent("Deck.pptx")
        try FileManager.default.createDirectory(at: localDeck.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deck".utf8).write(to: localDeck)

        let adapter = AppleScriptOfficeAdapter(
            app: .powerpoint,
            scriptExecutor: executor,
            snapshotStore: nil,
            cloudStorageRootsProvider: { [root] }
        )

        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-url-local",
            capturedAt: now,
            documents: [
                DocumentSnapshot(
                    app: .powerpoint,
                    displayName: "Deck",
                    canonicalPath: "https://d.docs.live.net/1234/Projects/Sber/Deck.pptx",
                    isSaved: true,
                    isTempArtifact: false,
                    capturedAt: now
                ),
            ],
            windowsMeta: [],
            restoreAttemptedForLaunch: false
        )

        _ = try await adapter.restore(snapshot: snapshot)
        guard let openScript = executedScripts.first(where: { $0.contains(" to open ") }) else {
            XCTFail("Expected an open script")
            return
        }
        XCTAssertTrue(openScript.contains("open POSIX file \"\(localDeck.path)\""))
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

    private static func extractPath(fromSaveScript script: String) -> String? {
        guard let markerRange = script.range(of: "POSIX file \"") else {
            return nil
        }
        let remainder = script[markerRange.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else {
            return nil
        }
        return String(remainder[..<end])
    }
}

private struct MockScriptExecutor: ScriptExecuting {
    let handler: (String) throws -> String

    func run(script: String) throws -> String {
        try handler(script)
    }
}
