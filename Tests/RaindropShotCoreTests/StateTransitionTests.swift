import XCTest
@testable import RaindropShotCore

final class StateTransitionTests: XCTestCase {
    func testStateSerializationRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(supportDirectory: tempDir)
        try paths.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        var state = WorkerState(trackingSince: now)
        let record = ShotRecord(
            path: "/Users/test/Desktop/Screenshot 1.png",
            identity: FileIdentity(device: 16777232, inode: 89412351),
            size: 1024,
            modifiedNanos: 1728340000_123456789,
            capturedAt: now,
            detectedAt: now,
            state: .pending
        )
        state.records.append(record)

        try StateStore.save(state, paths)
        let loaded = StateStore.load(paths, now: now).state

        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records[0].path, record.path)
        XCTAssertEqual(loaded.records[0].identity, record.identity)
        XCTAssertEqual(loaded.records[0].size, 1024)
        XCTAssertEqual(loaded.records[0].modifiedNanos, 1728340000_123456789)
        XCTAssertEqual(loaded.records[0].state, .pending)
    }

    func testTerminalStatesClassification() {
        XCTAssertFalse(ShotState.pending.isTerminal)
        XCTAssertFalse(ShotState.uploading.isTerminal)
        XCTAssertFalse(ShotState.uploaded.isTerminal)
        XCTAssertFalse(ShotState.unconfirmed.isTerminal)
        XCTAssertFalse(ShotState.rejected.isTerminal)

        XCTAssertTrue(ShotState.cleaned.isTerminal)
        XCTAssertTrue(ShotState.missing.isTerminal)
        XCTAssertTrue(ShotState.kept.isTerminal)
        XCTAssertTrue(ShotState.duplicate.isTerminal)
    }

    func testCorruptedStateFileRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(supportDirectory: tempDir)
        try paths.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write corrupt garbage into state.json
        let garbage = "INVALID_JSON_CORRUPTED_DATA".data(using: .utf8)!
        try garbage.write(to: paths.state)

        let now = Date()
        let result = StateStore.load(paths, now: now)

        switch result {
        case .recoveredFromCorruption(let recoveredState):
            XCTAssertEqual(recoveredState.trackingSince.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1.0)
            XCTAssertTrue(recoveredState.records.isEmpty)
        default:
            XCTFail("Expected recovery from corruption")
        }

        // Verify that corrupt file was preserved aside and not blindly deleted
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let corruptBackups = files.filter { $0.contains("state.corrupt") }
        XCTAssertFalse(corruptBackups.isEmpty, "Expected a corrupt backup copy to be created")
    }

    func testConstructPublicCoverURLAndPublicURL() {
        let id = 1880159189
        let fileName = "Screenshot 2026-10-08 at 1.14.16 AM.png"
        let constructed = ShotRecord.constructPublicCoverURL(id: id, fileName: fileName)
        let expected = "https://rdl.ink/render/https%3A%2F%2Fup.raindrop.io%2Fraindrop%2Ffiles%2F188%2F015%2F918%2F9%2FScreenshot_2026_10_08_at_1_14_16_AM.png"
        XCTAssertEqual(constructed, expected)

        var record = ShotRecord(
            path: "/Users/test/Desktop/\(fileName)",
            identity: FileIdentity(device: 1, inode: 2),
            size: 500,
            modifiedNanos: 0,
            capturedAt: Date(),
            detectedAt: Date()
        )
        record.raindropId = id

        // Fallback to deterministic public URL when raindropCover is nil
        XCTAssertEqual(record.publicURL, expected)

        // When raindropCover is explicitly set from API response, it takes priority
        let customCover = "https://rdl.ink/render/https%3A%2F%2Fcustom.png"
        record.raindropCover = customCover
        XCTAssertEqual(record.publicURL, customCover)
    }

    func testSettingsClipboardSerializationRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(supportDirectory: tempDir)
        try paths.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var settings = Settings(screenshotFolder: "/Users/test/Desktop")
        settings.copyScreenshotToClipboard = true
        settings.copyLinkToClipboardOnUpload = true

        try settings.save(to: paths)
        let loaded = Settings.load(from: paths)

        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded?.copyScreenshotToClipboard ?? false)
        XCTAssertTrue(loaded?.copyLinkToClipboardOnUpload ?? false)
    }
}
