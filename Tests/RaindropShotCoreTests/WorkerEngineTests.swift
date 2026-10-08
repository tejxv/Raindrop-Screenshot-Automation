import XCTest
@testable import RaindropShotCore

final class WorkerEngineTests: XCTestCase {
    var tempDir: URL!
    var screenshotsDir: URL!
    var paths: AppPaths!
    var mockAPI: MockRaindropAPI!
    var keychain: MockKeychain!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        screenshotsDir = tempDir.appendingPathComponent("Screenshots")
        try! FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        paths = AppPaths(supportDirectory: tempDir.appendingPathComponent("AppSupport"))
        try! paths.ensureDirectory()

        mockAPI = MockRaindropAPI()
        keychain = MockKeychain(initialToken: "test-valid-raindrop-token")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEndToEndScreenshotLifecycle() async throws {
        // 1. Configure settings
        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.uploadDelay = .asap
        settings.retention = .fiveMinutes
        settings.cleanupAction = .delete // using permanent delete for simple unit test assertions
        try settings.save(to: paths)

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        // 2. Create a test screenshot in the folder
        let shotURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-07 at 12.00.00.png")
        try "FAKE_IMAGE_DATA".write(to: shotURL, atomically: true, encoding: .utf8)

        // Baseline: set state tracking back slightly so this file is recognized
        let pastTime = Date().addingTimeInterval(-60)
        let state = WorkerState(trackingSince: pastTime)
        try StateStore.save(state, paths)

        // Wait 3 seconds in simulated time so the file is considered stable
        let runTime = Date().addingTimeInterval(5)

        // 3. First worker run: should discover and upload, but keep local file intact!
        let status1 = await engine.run(now: runTime)

        XCTAssertEqual(status1.health, .ok)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1, "Expected 1 upload to Raindrop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shotURL.path), "Screenshot MUST remain locally after upload!")

        let loadedState1 = StateStore.load(paths, now: runTime).state
        XCTAssertEqual(loadedState1.records.count, 1)
        let record = loadedState1.records[0]
        XCTAssertEqual(record.state, .uploaded)
        XCTAssertEqual(record.raindropId, 12345)

        // 4. Second run shortly after (e.g. 2 minutes later < 5 min retention): file must still remain untouched
        let runTime2 = runTime.addingTimeInterval(120)
        let status2 = await engine.run(now: runTime2)
        XCTAssertEqual(status2.health, .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shotURL.path), "Screenshot MUST remain during retention period")

        // 5. Third run after retention elapsed (e.g. 6 minutes later > 5 min retention): file should be cleaned up
        let runTime3 = runTime.addingTimeInterval(360)
        let status3 = await engine.run(now: runTime3)
        XCTAssertEqual(status3.health, .ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shotURL.path), "Screenshot should be deleted after retention period")

        let loadedState3 = StateStore.load(paths, now: runTime3).state
        XCTAssertEqual(loadedState3.records[0].state, .cleaned)
    }

    func testDryRunDoesNotMutateNetworkOrFiles() async throws {
        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.uploadDelay = .asap
        try settings.save(to: paths)

        let shotURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-07 at 12.00.00.png")
        try "FAKE_IMAGE_DATA".write(to: shotURL, atomically: true, encoding: .utf8)

        let state = WorkerState(trackingSince: Date().addingTimeInterval(-60))
        try StateStore.save(state, paths)

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        let options = WorkerEngineOptions(dryRun: true)
        let status = await engine.run(options: options, now: Date().addingTimeInterval(5))

        XCTAssertEqual(status.health, .ok)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 0, "Dry run must NOT make network uploads")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shotURL.path), "Dry run must NOT delete files")
    }

    func testUserEditAfterUploadPreventsDeletion() async throws {
        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.uploadDelay = .asap
        settings.retention = .fiveMinutes
        settings.cleanupAction = .delete
        try settings.save(to: paths)

        let shotURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-07.png")
        try "INITIAL_CONTENT".write(to: shotURL, atomically: true, encoding: .utf8)

        let state = WorkerState(trackingSince: Date().addingTimeInterval(-60))
        try StateStore.save(state, paths)

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        let runTime = Date().addingTimeInterval(5)
        await engine.run(now: runTime)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)

        // User edits the file locally!
        sleep(1)
        try "MODIFIED_ANNOTATED_CONTENT".write(to: shotURL, atomically: true, encoding: .utf8)

        // Run after retention elapsed
        let runTimeAfterRetention = runTime.addingTimeInterval(400)
        await engine.run(now: runTimeAfterRetention)

        // Edited file MUST be preserved locally (marked .kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shotURL.path), "Locally edited file must NEVER be deleted!")
        let finalState = StateStore.load(paths, now: runTimeAfterRetention).state
        XCTAssertEqual(finalState.records[0].state, .kept)
    }

    func testUploadFailureRetryAndBackoff() async throws {
        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.uploadDelay = .asap
        try settings.save(to: paths)

        let shotURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-07.png")
        try "IMAGE_DATA".write(to: shotURL, atomically: true, encoding: .utf8)

        let state = WorkerState(trackingSince: Date().addingTimeInterval(-60))
        try StateStore.save(state, paths)

        // Configure mock API to fail with 500 server error
        mockAPI.uploadResult = .failure(.serverError(statusCode: 500))

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        let runTime = Date().addingTimeInterval(5)
        let status = await engine.run(now: runTime)

        XCTAssertEqual(status.health, .error)
        let loadedState = StateStore.load(paths, now: runTime).state
        XCTAssertEqual(loadedState.records.count, 1)
        let record = loadedState.records[0]
        XCTAssertEqual(record.state, .pending)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertNotNil(record.nextRetryAt)
        XCTAssertTrue(record.nextRetryAt! > runTime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shotURL.path), "Failed file must remain untouched")
    }

    func testPruneTerminalRecords() async throws {
        var state = WorkerState(trackingSince: Date().addingTimeInterval(-1_000_000))

        // Create 1 recent record and 1 old cleaned record (> 7 days old)
        let recentRecord = ShotRecord(
            path: "/tmp/shot1.png",
            identity: FileIdentity(device: 1, inode: 100),
            size: 100,
            modifiedNanos: 100,
            capturedAt: Date(),
            detectedAt: Date(),
            state: .cleaned
        )
        var recent = recentRecord
        recent.finishedAt = Date().addingTimeInterval(-86400) // 1 day ago

        var old = recentRecord
        old.identity = FileIdentity(device: 1, inode: 101)
        old.finishedAt = Date().addingTimeInterval(-10 * 86400) // 10 days ago

        state.records = [recent, old]
        try StateStore.save(state, paths)

        let settings = Settings(screenshotFolder: screenshotsDir.path)
        try settings.save(to: paths)

        let engine = WorkerEngine(paths: paths, api: mockAPI, keychain: keychain)
        await engine.run(now: Date())

        let loaded = StateStore.load(paths, now: Date()).state
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(loaded.records[0].identity.inode, 100, "Old finished record should be pruned")
    }
}
