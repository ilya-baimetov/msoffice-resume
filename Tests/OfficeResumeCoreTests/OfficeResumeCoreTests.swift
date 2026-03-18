import XCTest
@testable import OfficeResumeCore

final class OfficeResumeCoreTests: XCTestCase {
    func testDaemonSharedIPCStatusRoundTrip() throws {
        let status = DaemonStatusDTO(
            isPaused: false,
            helperRunning: true,
            accessibilityTrusted: true,
            entitlementActive: true,
            entitlementPlan: .yearly,
            entitlementValidUntil: Date(timeIntervalSince1970: 1_800_000_000),
            entitlementTrialEndsAt: nil,
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

    func testDaemonStatusRoundTripIncludesSnapshotState() throws {
        let status = DaemonStatusDTO(
            isPaused: false,
            helperRunning: true,
            accessibilityTrusted: false,
            entitlementActive: true,
            entitlementPlan: .trial,
            entitlementValidUntil: Date(timeIntervalSince1970: 1_700_086_400),
            entitlementTrialEndsAt: Date(timeIntervalSince1970: 1_700_086_400),
            latestSnapshotCapturedAt: [.word: Date(timeIntervalSince1970: 1_700_000_000)],
            unsupportedApps: [.onenote]
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(DaemonStatusDTO.self, from: data)
        XCTAssertEqual(decoded.latestSnapshotCapturedAt[.word], status.latestSnapshotCapturedAt[.word])
        XCTAssertEqual(decoded.accessibilityTrusted, status.accessibilityTrusted)
    }

    func testDaemonStatusLegacyDecodeDefaultsAccessibilityTrustedToFalse() throws {
        let json = """
        {
          "isPaused": false,
          "helperRunning": true,
          "entitlementActive": true,
          "entitlementPlan": "trial",
          "entitlementValidUntil": null,
          "entitlementTrialEndsAt": null,
          "latestSnapshotCapturedAt": [],
          "unsupportedApps": ["onenote"]
        }
        """

        let decoded = try JSONDecoder().decode(DaemonStatusDTO.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.accessibilityTrusted)
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

    func testDocumentSnapshotDecodesLegacyEmptyPathAsNil() throws {
        let json = """
        {
          "app": "word",
          "displayName": "Untitled 1",
          "canonicalPath": "",
          "isSaved": false,
          "isTempArtifact": false,
          "capturedAt": "2023-11-14T22:13:20Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DocumentSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.canonicalPath)
    }

    func testAutomaticRestoreAppsExcludeOutlookLifecycleOnlyMode() {
        XCTAssertEqual(OfficeBundleRegistry.automaticRestoreApps, [.word, .excel, .powerpoint])
        XCTAssertEqual(OfficeBundleRegistry.lifecycleOnlyApps, [.outlook])
        XCTAssertFalse(OfficeBundleRegistry.automaticRestoreApps.contains(.outlook))
    }

    func testRestoreEngineDedupeAndOneShotMarker() async throws {
        let tempRoot = makeTempDirectory(name: "restore-engine")
        let snapshotStore = FileSnapshotStore(
            channel: .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix),
            baseDirectoryOverride: tempRoot
        )
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
            windowsMeta: []
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
        XCTAssertEqual(plan?.documentsToOpen.compactMap(\.canonicalPath), ["/tmp/b.docx"])

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
        let snapshotStore = FileSnapshotStore(
            channel: .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix),
            baseDirectoryOverride: tempRoot
        )
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
            windowsMeta: []
        )
        try await snapshotStore.saveSnapshot(snapshot)

        let plan = try await engine.buildPlan(
            for: .powerpoint,
            launchInstanceID: "new-launch",
            currentlyOpenDocuments: []
        )

        XCTAssertEqual(plan?.documentsToOpen.compactMap(\.canonicalPath), ["/tmp/demo.pptx"])
    }

    func testFileSnapshotStoreRoundTripAndEvents() async throws {
        let tempRoot = makeTempDirectory(name: "snapshot-store")
        let store = FileSnapshotStore(
            channel: .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix),
            baseDirectoryOverride: tempRoot
        )

        let snapshot = AppSnapshot(
            app: .excel,
            launchInstanceID: "launch-1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            documents: [makeDocument(path: "/tmp/sheet.xlsx", app: .excel)],
            windowsMeta: []
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
        let store = FileSnapshotStore(
            channel: .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix),
            baseDirectoryOverride: tempRoot
        )
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

    func testFolderAccessStorePersistsGrantsAndPrefersDeepestMatchingRoot() async throws {
        let tempRoot = makeTempDirectory(name: "folder-access")
        let documentsURL = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        let projectURL = documentsURL.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let store = FolderAccessStore(baseDirectoryOverride: tempRoot)
        try await store.grantDirectories([documentsURL, projectURL])

        let grants = try await store.loadGrants()
        XCTAssertEqual(grants.count, 2)

        let storedFile = tempRoot
            .appendingPathComponent("restore", isDirectory: true)
            .appendingPathComponent("folder-access-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedFile.path))

        let documentPath = projectURL.appendingPathComponent("deck.pptx").path
        let matchedGrant = FolderAccessStore.bestMatchingGrant(for: documentPath, in: grants)
        XCTAssertEqual(matchedGrant?.rootPath, projectURL.standardizedFileURL.path)
    }

    func testFolderAccessStoreDoesNotCrossDirectoryBoundaries() async {
        let grants = [
            FolderAccessGrant(
                id: "documents",
                displayName: "Documents",
                rootPath: "/Users/test/Documents",
                bookmarkData: Data(),
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]

        let matchedGrant = FolderAccessStore.bestMatchingGrant(
            for: "/Users/test/Documents Archive/file.docx",
            in: grants
        )
        XCTAssertNil(matchedGrant)
    }

    func testCachedEntitlementProviderIsInactiveWithoutCacheOrRemote() async throws {
        let store = try EntitlementFileStore(baseDirectory: makeTempDirectory(name: "inactive-entitlement"))
        let provider = makeIsolatedCachedProvider(store: store, now: Date.init)

        let initial = await provider.currentState()
        XCTAssertFalse(initial.isActive)
        XCTAssertEqual(initial.plan, .none)
    }

    func testOfflineGraceDisablesAfterSevenDays() async throws {
        let baseNow = Date(timeIntervalSince1970: 1_700_000_000)
        var now = baseNow

        let store = try EntitlementFileStore(baseDirectory: makeTempDirectory(name: "offline-grace"))
        let provider = makeIsolatedCachedProvider(store: store, now: { now })

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

    func testDebugEntitlementBypassRequiresExplicitFlag() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let disabled = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            environment: [:]
        )
        XCTAssertNil(disabled)

        let enabled = DebugEntitlementBypassEvaluator.overrideState(
            now: now,
            environment: ["OFFICE_RESUME_ENABLE_DEBUG_ENTITLEMENT_BYPASS": "1"]
        )

#if DEBUG
        XCTAssertNotNil(enabled)
        XCTAssertEqual(enabled?.isActive, true)
        XCTAssertEqual(enabled?.plan, .yearly)
#else
        XCTAssertNil(enabled)
#endif
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
        XCTAssertEqual(
            RuntimeConfiguration.storageChannel(for: channel),
            .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix)
        )
    }

    func testForceSaveUntitledPersistsRealArtifactAndIndex() async throws {
        let tempRoot = makeTempDirectory(name: "force-save")
        let store = FileSnapshotStore(
            channel: .applicationSupport(bundlePrefix: RuntimeConfiguration.bundlePrefix),
            baseDirectoryOverride: tempRoot
        )
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
                    canonicalPath: nil,
                    isSaved: false,
                    isTempArtifact: false,
                    capturedAt: Date()
                ),
            ],
            windowsMeta: []
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
            windowsMeta: []
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
            if script.contains(" to get name") {
                return "PowerPoint"
            }
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
            windowsMeta: []
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/retry.pptx"])
        XCTAssertEqual(openAttempts, 3)
    }

    func testRestoreWaitsForApplicationReadinessBeforeOpeningDocuments() async throws {
        var readinessAttempts = 0
        var openAttempts = 0

        let executor = MockScriptExecutor { script in
            if script.contains(" to get name") {
                readinessAttempts += 1
                if readinessAttempts < 4 {
                    throw NSError(
                        domain: "OfficeResumeAppleScript",
                        code: -600,
                        userInfo: [NSLocalizedDescriptionKey: "Application isn’t running"]
                    )
                }
                return "Microsoft PowerPoint"
            }

            if script.contains(" to open ") {
                openAttempts += 1
            }

            return "ok"
        }

        let adapter = AppleScriptOfficeAdapter(app: .powerpoint, scriptExecutor: executor, snapshotStore: nil)
        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-ready",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Deck", canonicalPath: "/tmp/ready.pptx", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: []
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/ready.pptx"])
        XCTAssertEqual(readinessAttempts, 4)
        XCTAssertEqual(openAttempts, 1)
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
            windowsMeta: []
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
            windowsMeta: []
        )

        _ = try await adapter.restore(snapshot: snapshot)
        guard let openScript = executedScripts.first(where: { $0.contains(" to open ") }) else {
            XCTFail("Expected an open script")
            return
        }
        XCTAssertTrue(openScript.contains("open POSIX file \"\(localDeck.path)\""))
    }

    func testRestoreUsesDocumentOpenerForRuntimeOpenPath() async throws {
        var executedScripts: [String] = []
        var openedPaths: [String] = []

        let executor = MockScriptExecutor { script in
            executedScripts.append(script)
            if script.contains(" to open ") {
                XCTFail("Runtime open path should use document opener")
            }
            return "ok"
        }

        let opener = MockDocumentOpener { path, _ in
            openedPaths.append(path)
        }

        let root = makeTempDirectory(name: "runtime-onedrive-root")
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
            documentOpener: opener,
            snapshotStore: nil,
            cloudStorageRootsProvider: { [root] }
        )

        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-runtime-open",
            capturedAt: now,
            documents: [
                DocumentSnapshot(
                    app: .powerpoint,
                    displayName: "Cloud Deck",
                    canonicalPath: "https://d.docs.live.net/1234/Projects/Sber/Deck.pptx",
                    isSaved: true,
                    isTempArtifact: false,
                    capturedAt: now
                ),
                DocumentSnapshot(
                    app: .powerpoint,
                    displayName: "Local Deck",
                    canonicalPath: "/tmp/local-deck.pptx",
                    isSaved: true,
                    isTempArtifact: false,
                    capturedAt: now
                ),
            ],
            windowsMeta: []
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, [localDeck.path, "/tmp/local-deck.pptx"])
        XCTAssertEqual(openedPaths, [localDeck.path, "/tmp/local-deck.pptx"])
    }

    func testRestoreRetriesTransientDocumentOpenerFailure() async throws {
        var readinessAttempts = 0
        var openAttempts = 0
        var scriptOpenAttempts = 0

        let executor = MockScriptExecutor { script in
            if script.contains(" to get name") {
                readinessAttempts += 1
                return "Microsoft PowerPoint"
            }
            if script.contains(" to open ") {
                scriptOpenAttempts += 1
                if scriptOpenAttempts < 3 {
                    throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "script open not ready"])
                }
            }
            return "ok"
        }

        let opener = MockDocumentOpener { _, _ in
            openAttempts += 1
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "not ready"])
        }

        let adapter = AppleScriptOfficeAdapter(
            app: .powerpoint,
            scriptExecutor: executor,
            documentOpener: opener,
            snapshotStore: nil
        )

        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-runtime-retry",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Deck", canonicalPath: "/tmp/retry-runtime.pptx", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: []
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/retry-runtime.pptx"])
        XCTAssertEqual(openAttempts, 3)
        XCTAssertEqual(scriptOpenAttempts, 3)
        XCTAssertGreaterThanOrEqual(readinessAttempts, 1)
    }

    func testRestoreFallsBackToOfficeScriptWhenDocumentOpenerFails() async throws {
        var executedScripts: [String] = []
        var openAttempts = 0

        let executor = MockScriptExecutor { script in
            executedScripts.append(script)
            if script.contains(" to get name") {
                return "Microsoft PowerPoint"
            }
            if script.contains(" to open ") {
                return "ok"
            }
            return "ok"
        }

        let opener = MockDocumentOpener { _, _ in
            openAttempts += 1
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The application could not be launched because a miscellaneous error occurred."]
            )
        }

        let adapter = AppleScriptOfficeAdapter(
            app: .powerpoint,
            scriptExecutor: executor,
            documentOpener: opener,
            snapshotStore: nil
        )

        let now = Date()
        let snapshot = AppSnapshot(
            app: .powerpoint,
            launchInstanceID: "launch-runtime-fallback",
            capturedAt: now,
            documents: [
                DocumentSnapshot(app: .powerpoint, displayName: "Deck", canonicalPath: "/tmp/fallback-runtime.pptx", isSaved: true, isTempArtifact: false, capturedAt: now),
            ],
            windowsMeta: []
        )

        let result = try await adapter.restore(snapshot: snapshot)
        XCTAssertEqual(result.failedPaths, [])
        XCTAssertEqual(result.restoredPaths, ["/tmp/fallback-runtime.pptx"])
        XCTAssertEqual(openAttempts, 1)
        XCTAssertTrue(executedScripts.contains(where: { $0.contains(" to open POSIX file \"/tmp/fallback-runtime.pptx\"") }))
    }

    func testDirectAccountProviderMapsSubscribeBillingAction() async throws {
        try await withIsolatedDirectSessionStore { sessionStore in
            let sessionToken = "session-subscribe"
            try await sessionStore.save(DirectSession(email: "user@example.com", sessionToken: sessionToken))

            let provider = try self.makeDirectAccountProvider { request in
                switch request.url?.path {
                case "/entitlements/current":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(sessionToken)")
                    return Self.jsonHTTPResponse(
                        statusCode: 200,
                        url: request.url!,
                        json: """
                        {
                          "isActive": true,
                          "plan": "trial",
                          "validUntil": "2026-03-28T12:00:00Z",
                          "trialEndsAt": "2026-03-28T12:00:00Z"
                        }
                        """
                    )
                case "/billing/entry":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(sessionToken)")
                    return Self.jsonHTTPResponse(
                        statusCode: 200,
                        url: request.url!,
                        json: """
                        {
                          "kind": "subscribe",
                          "title": "Choose Plan…",
                          "url": "https://billing.example.com/pricing?entry=abc"
                        }
                        """
                    )
                default:
                    XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            let state = try await provider.refreshAccountState()
            XCTAssertEqual(state.email, "user@example.com")
            XCTAssertEqual(state.entitlement.plan, .trial)
            XCTAssertEqual(state.billingAction?.kind, .subscribe)
            XCTAssertEqual(state.billingAction?.title, "Choose Plan…")
        }
    }

    func testDirectAccountProviderMapsManageSubscriptionBillingAction() async throws {
        try await withIsolatedDirectSessionStore { sessionStore in
            let sessionToken = "session-manage"
            try await sessionStore.save(DirectSession(email: "paid@example.com", sessionToken: sessionToken))

            let provider = try self.makeDirectAccountProvider { request in
                switch request.url?.path {
                case "/entitlements/current":
                    return Self.jsonHTTPResponse(
                        statusCode: 200,
                        url: request.url!,
                        json: """
                        {
                          "isActive": true,
                          "plan": "monthly",
                          "validUntil": "2026-04-14T12:00:00Z",
                          "trialEndsAt": null
                        }
                        """
                    )
                case "/billing/entry":
                    return Self.jsonHTTPResponse(
                        statusCode: 200,
                        url: request.url!,
                        json: """
                        {
                          "kind": "manageSubscription",
                          "title": "Manage Subscription",
                          "url": "https://billing.example.com/portal"
                        }
                        """
                    )
                default:
                    XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            let state = try await provider.refreshAccountState()
            XCTAssertEqual(state.billingAction?.kind, .manageSubscription)
            XCTAssertEqual(state.billingAction?.title, "Manage Subscription")
        }
    }

    func testDirectAccountProviderReturnsNoBillingActionWhenBackendRespondsNoContent() async throws {
        try await withIsolatedDirectSessionStore { sessionStore in
            let sessionToken = "session-free-pass"
            try await sessionStore.save(DirectSession(email: "free@example.com", sessionToken: sessionToken))

            let provider = try self.makeDirectAccountProvider { request in
                switch request.url?.path {
                case "/entitlements/current":
                    return Self.jsonHTTPResponse(
                        statusCode: 200,
                        url: request.url!,
                        json: """
                        {
                          "isActive": true,
                          "plan": "yearly",
                          "validUntil": "2027-03-14T12:00:00Z",
                          "trialEndsAt": null
                        }
                        """
                    )
                case "/billing/entry":
                    return Self.emptyHTTPResponse(statusCode: 204, url: request.url!)
                default:
                    XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            let state = try await provider.refreshAccountState()
            XCTAssertNil(state.billingAction)
        }
    }

    func testDirectAccountProviderAcceptsBillingRefreshCallbackWhenSignedIn() async throws {
        try await withIsolatedDirectSessionStore { sessionStore in
            try await sessionStore.save(DirectSession(email: "user@example.com", sessionToken: "session-refresh"))

            let provider = try self.makeDirectAccountProvider(sessionStore: sessionStore) { request in
                XCTFail("Unexpected network request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }

            let handled = try await provider.handleIncomingURL(
                URL(string: "officeresume-direct://auth?action=billingRefresh")!
            )
            XCTAssertTrue(handled)
        }
    }

    func testDirectAccountProviderRejectsBillingRefreshCallbackWhenSignedOut() async throws {
        try await withIsolatedDirectSessionStore { sessionStore in
            let provider = try self.makeDirectAccountProvider(sessionStore: sessionStore) { request in
                XCTFail("Unexpected network request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }

            let handled = try await provider.handleIncomingURL(
                URL(string: "officeresume-direct://auth?billingRefresh=1")!
            )
            XCTAssertFalse(handled)
        }
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

    private func makeIsolatedCachedProvider(
        store: EntitlementFileStore,
        now: @escaping () -> Date
    ) -> CachedEntitlementProvider {
        return CachedEntitlementProvider(
            store: store,
            now: now,
            overrideEnvironment: [:]
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

    private func makeDirectAccountProvider(
        sessionStore: DirectSessionKeychainStore = DirectSessionKeychainStore(),
        requestHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> DirectAccountProvider {
        let store = try EntitlementFileStore(baseDirectory: makeTempDirectory(name: "direct-account-entitlements"))
        let configuration = DirectServiceConfiguration(
            baseURL: URL(string: "https://example.com")!,
            callbackScheme: "officeresume-direct"
        )
        let session = try Self.makeMockSession(requestHandler: requestHandler)
        let userDefaultsSuite = "OfficeResumeTests.DirectAccount.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuite) ?? .standard
        userDefaults.removePersistentDomain(forName: userDefaultsSuite)

        return DirectAccountProvider(
            configuration: configuration,
            sessionStore: sessionStore,
            entitlementStore: store,
            session: session,
            userDefaults: userDefaults
        )
    }

    private func withIsolatedDirectSessionStore(
        _ body: @escaping (DirectSessionKeychainStore) async throws -> Void
    ) async throws {
        let sessionStore = DirectSessionKeychainStore()
        let originalSession = try await sessionStore.load()
        try await sessionStore.clear()

        do {
            try await body(sessionStore)
        } catch {
            try? await sessionStore.clear()
            if let originalSession {
                try? await sessionStore.save(originalSession)
            }
            throw error
        }

        try await sessionStore.clear()
        if let originalSession {
            try await sessionStore.save(originalSession)
        }
    }

    private static func makeMockSession(
        requestHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> URLSession {
        MockURLProtocol.requestHandler = requestHandler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonHTTPResponse(statusCode: Int, url: URL, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private static func emptyHTTPResponse(statusCode: Int, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data())
    }
}

private struct MockScriptExecutor: ScriptExecuting {
    let handler: (String) throws -> String

    func run(script: String) throws -> String {
        try handler(script)
    }
}

private struct MockDocumentOpener: DocumentOpening {
    let handler: (String, OfficeApp) async throws -> Void

    func open(path: String, app: OfficeApp) async throws {
        try await handler(path, app)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
