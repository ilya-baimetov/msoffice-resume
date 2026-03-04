import XCTest
@testable import OfficeResumeCore

final class OfficeResumeCoreTests: XCTestCase {
    func testPollingIntervalSecondsMapping() {
        XCTAssertEqual(PollingInterval.oneSecond.seconds, 1)
        XCTAssertEqual(PollingInterval.fiveSeconds.seconds, 5)
        XCTAssertEqual(PollingInterval.fifteenSeconds.seconds, 15)
        XCTAssertEqual(PollingInterval.oneMinute.seconds, 60)
        XCTAssertNil(PollingInterval.none.seconds)
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
}
