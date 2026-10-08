import XCTest
@testable import RaindropShotCore

final class SweepTests: XCTestCase {
    private var tempDir: URL!
    private var screenshotsDir: URL!
    private var paths: AppPaths!
    private var keychain: MockKeychain!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        screenshotsDir = tempDir.appendingPathComponent("Screenshots")
        try! FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        paths = AppPaths(supportDirectory: tempDir.appendingPathComponent("AppSupport"))
        try! paths.ensureDirectory()

        keychain = MockKeychain(initialToken: "test-token")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Discovery Tests

    func testDiscoverCandidatesFindsBacklogAndSortsOldestFirst() throws {
        let now = Date()
        let t1 = now.addingTimeInterval(-7200) // 2 hours ago
        let t2 = now.addingTimeInterval(-3600) // 1 hour ago
        let t3 = now.addingTimeInterval(-10800) // 3 hours ago

        let file1 = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 10.00.00 AM.png")
        let file2 = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 11.00.00 AM.png")
        let file3 = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 09.00.00 AM.png")
        let nonScreenshot = screenshotsDir.appendingPathComponent("document.pdf")

        try "data1".write(to: file1, atomically: true, encoding: .utf8)
        try "data2".write(to: file2, atomically: true, encoding: .utf8)
        try "data3".write(to: file3, atomically: true, encoding: .utf8)
        try "doc".write(to: nonScreenshot, atomically: true, encoding: .utf8)

        // Set explicit file timestamps
        try FileManager.default.setAttributes([.creationDate: t1, .modificationDate: t1], ofItemAtPath: file1.path)
        try FileManager.default.setAttributes([.creationDate: t2, .modificationDate: t2], ofItemAtPath: file2.path)
        try FileManager.default.setAttributes([.creationDate: t3, .modificationDate: t3], ofItemAtPath: file3.path)

        // Baseline is "now", so in normal mode these historical files would be ignored
        let state = WorkerState(trackingSince: now)

        let candidates = SweepCoordinator.discoverCandidates(folderURL: screenshotsDir, state: state)

        // Non-screenshot must be filtered out
        XCTAssertEqual(candidates.count, 3)

        // Oldest first: t3 (9 AM) -> t1 (10 AM) -> t2 (11 AM)
        XCTAssertEqual(candidates[0].url.lastPathComponent, file3.lastPathComponent)
        XCTAssertEqual(candidates[1].url.lastPathComponent, file1.lastPathComponent)
        XCTAssertEqual(candidates[2].url.lastPathComponent, file2.lastPathComponent)
    }

    func testDiscoverCandidatesExcludesAlreadyHandledTerminalRecords() throws {
        let file1 = screenshotsDir.appendingPathComponent("Screenshot 1.png")
        let file2 = screenshotsDir.appendingPathComponent("Screenshot 2.png")
        let file3 = screenshotsDir.appendingPathComponent("Screenshot 3.png")

        try "data1".write(to: file1, atomically: true, encoding: .utf8)
        try "data2".write(to: file2, atomically: true, encoding: .utf8)
        try "data3".write(to: file3, atomically: true, encoding: .utf8)

        guard let meta1 = FileOperations.metadata(for: file1),
              let meta2 = FileOperations.metadata(for: file2) else {
            XCTFail("Failed to read metadata")
            return
        }

        var state = WorkerState(trackingSince: Date())
        // Record 1 is already uploaded
        state.records.append(
            ShotRecord(
                path: file1.path,
                identity: meta1.identity,
                size: meta1.size,
                modifiedNanos: meta1.modifiedNanos,
                capturedAt: meta1.capturedAt,
                detectedAt: Date(),
                state: .uploaded
            )
        )
        // Record 2 is already cleaned
        state.records.append(
            ShotRecord(
                path: file2.path,
                identity: meta2.identity,
                size: meta2.size,
                modifiedNanos: meta2.modifiedNanos,
                capturedAt: meta2.capturedAt,
                detectedAt: Date(),
                state: .cleaned
            )
        )

        let candidates = SweepCoordinator.discoverCandidates(folderURL: screenshotsDir, state: state)

        // Only Screenshot 3 is eligible!
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].url.lastPathComponent, "Screenshot 3.png")
    }

    // MARK: - End-to-End Processing

    func testRunSweepProcessesBacklogThroughCanonicalPipeline() async throws {
        let file1 = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 10.00.00 AM.png")
        let file2 = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 10.05.00 AM.png")

        try "image1".write(to: file1, atomically: true, encoding: .utf8)
        try "image2".write(to: file2, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.smartNamingApplyTo = .both
        settings.tags = ["archived", "backlog"]
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "borrowbox-rental-dashboard",
                    title: "BorrowBox Rental Dashboard",
                    description: "Rental dashboard overview"
                )
            )
        )

        let coordinator = SweepCoordinator(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            namer: mockNamer
        )

        let status = await coordinator.runSweep(now: Date().addingTimeInterval(10))

        XCTAssertEqual(status.state, SweepStatus.State.completed)
        XCTAssertEqual(status.phase, SweepStatus.Phase.complete)
        XCTAssertEqual(status.total, 2)
        XCTAssertEqual(status.completed, 2)
        XCTAssertEqual(status.uploaded, 2)
        XCTAssertEqual(status.skipped, 0)
        XCTAssertEqual(status.failed, 0)
        XCTAssertEqual(status.remaining, 0)

        // Check Raindrop API invocations
        XCTAssertEqual(mockAPI.uploadedFiles.count, 2)
        XCTAssertEqual(mockAPI.updatedMetadata.count, 2)
        XCTAssertEqual(mockAPI.updatedMetadata[0].title, "BorrowBox Rental Dashboard")
        XCTAssertEqual(mockAPI.updatedMetadata[0].tags, ["archived", "backlog"])

        // Check model finishBatch was called
        XCTAssertTrue(mockNamer.batchFinished)

        // Check state file
        let workerState = StateStore.load(paths, now: Date()).state
        XCTAssertEqual(workerState.records.count, 2)
        for rec in workerState.records {
            XCTAssertEqual(rec.state, ShotState.uploaded)
            XCTAssertEqual(rec.generatedFilename, "borrowbox-rental-dashboard")
            XCTAssertNotNil(rec.raindropId)
            XCTAssertNotNil(rec.publicURL)
        }

        // Check local files were safely renamed
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("borrowbox-rental-dashboard.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotsDir.appendingPathComponent("borrowbox-rental-dashboard-2.png").path))
    }

    // MARK: - Idempotency & Repeat Runs

    func testRunSweepIdempotencyNoDuplicatesOnSecondRun() async throws {
        let file = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 08.00.00 AM.png")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .off
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let coordinator = SweepCoordinator(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        // First run
        let status1 = await coordinator.runSweep(now: Date().addingTimeInterval(10))
        XCTAssertEqual(status1.total, 1)
        XCTAssertEqual(status1.uploaded, 1)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)

        // Second run immediately
        let status2 = await coordinator.runSweep(now: Date().addingTimeInterval(20))
        XCTAssertEqual(status2.total, 0)
        XCTAssertEqual(status2.uploaded, 0)
        XCTAssertEqual(status2.state, SweepStatus.State.completed)
        // No redundant network calls
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)
    }

    // MARK: - Stop & Interruption Handling

    func testSweepStopRequestInterruptsExecutionCleanly() async throws {
        // Create 3 files
        for i in 1...3 {
            let f = screenshotsDir.appendingPathComponent("Screenshot \(i).png")
            try "data\(i)".write(to: f, atomically: true, encoding: .utf8)
        }

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .off
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let coordinator = SweepCoordinator(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        // Request stop via static helper
        SweepCoordinator.requestStop(paths: paths)

        let status = await coordinator.runSweep(now: Date().addingTimeInterval(10))

        XCTAssertEqual(status.state, SweepStatus.State.stopped)
        XCTAssertEqual(status.total, 3)
        // Stopped before processing candidates
        XCTAssertEqual(status.uploaded, 0)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 0)
    }

    // MARK: - Error Handling & Resilience

    func testSweepMissingFileHandledGracefully() async throws {
        let file1 = screenshotsDir.appendingPathComponent("Screenshot 1.png")
        let file2 = screenshotsDir.appendingPathComponent("Screenshot 2.png")

        try "data1".write(to: file1, atomically: true, encoding: .utf8)
        try "data2".write(to: file2, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .off
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let coordinator = SweepCoordinator(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        // Delete file 1 from disk right before sweep processes it
        try FileManager.default.removeItem(at: file1)

        let status = await coordinator.runSweep(now: Date().addingTimeInterval(10))

        // Total was discovered initially (or filtered)
        // File 2 was uploaded
        XCTAssertEqual(status.uploaded, 1)
        XCTAssertEqual(status.state, SweepStatus.State.completed)
    }

    func testSweepNetworkFailureLeavesItemPending() async throws {
        let file = screenshotsDir.appendingPathComponent("Screenshot 1.png")
        try "data1".write(to: file, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .off
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI(uploadResult: .failure(.offline(message: "No internet")))
        let coordinator = SweepCoordinator(
            paths: paths,
            api: mockAPI,
            keychain: keychain
        )

        let status = await coordinator.runSweep(now: Date().addingTimeInterval(10))

        XCTAssertEqual(status.state, SweepStatus.State.waitingForConnection)
        XCTAssertEqual(status.completed, 0)
        XCTAssertEqual(status.uploaded, 0)

        // Record remains pending in state
        let workerState = StateStore.load(paths, now: Date()).state
        XCTAssertEqual(workerState.records.first?.state, ShotState.pending)
    }
}
