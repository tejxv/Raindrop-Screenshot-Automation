import XCTest
@testable import RaindropShotCore

final class SmartNamingTests: XCTestCase {
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

        // Set tracking baseline to past so newly created test screenshots are eligible
        let state = WorkerState(trackingSince: Date().addingTimeInterval(-60))
        try! StateStore.save(state, paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Sanitization Tests

    func testFilenameSanitizerCleansGenericWordsAndTimestamps() {
        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "borrowbox-generator-rental-dashboard",
                fallback: "original"
            ),
            "borrowbox-generator-rental-dashboard"
        )

        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "Screenshot 2026-10-08 at 1.03.42 PM",
                fallback: "my-custom-doc"
            ),
            "my-custom-doc"
        )

        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "Apple Foundation Models Docs.png",
                fallback: "fallback"
            ),
            "apple-foundation-models-docs"
        )

        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "Figma: iOS Settings Screen (Final)",
                fallback: "fallback"
            ),
            "figma-ios-settings-final"
        )

        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "RevenueCat Trial Customer Details",
                fallback: "fallback"
            ),
            "revenuecat-trial-customer-details"
        )

        XCTAssertEqual(
            FilenameSanitizer.sanitizeBaseName(
                rawName: "---Screenshot---of---a---window---",
                fallback: "project-spec"
            ),
            "project-spec"
        )
    }

    func testFilenameSanitizerTruncatesToSixWords() {
        let longName = "one-two-three-four-five-six-seven-eight-nine"
        let sanitized = FilenameSanitizer.sanitizeBaseName(rawName: longName, fallback: "fb")
        let words = sanitized.split(separator: "-")
        XCTAssertLessThanOrEqual(words.count, 6)
        XCTAssertEqual(sanitized, "one-two-three-four-five-six")
    }

    // MARK: - Collision Resolution Tests

    func testFilenameSanitizerCollisionResolution() throws {
        let dir = tempDir.appendingPathComponent("collisionTest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let target1 = dir.appendingPathComponent("borrowbox-dashboard.png")
        try "file1".write(to: target1, atomically: true, encoding: .utf8)

        // Resolving when borrowbox-dashboard.png already exists
        let resolved2 = FilenameSanitizer.resolveSafeDestinationURL(
            in: dir,
            desiredBaseName: "borrowbox-dashboard",
            extension: "png"
        )
        XCTAssertEqual(resolved2.lastPathComponent, "borrowbox-dashboard-2.png")

        // Create the second file
        try "file2".write(to: resolved2, atomically: true, encoding: .utf8)

        // Resolving when both 1 and 2 exist
        let resolved3 = FilenameSanitizer.resolveSafeDestinationURL(
            in: dir,
            desiredBaseName: "borrowbox-dashboard",
            extension: "png"
        )
        XCTAssertEqual(resolved3.lastPathComponent, "borrowbox-dashboard-3.png")

        // If checking same identity, returns the existing file without duplicate index
        let meta1 = FileOperations.metadata(for: target1)!
        let resolvedSelf = FilenameSanitizer.resolveSafeDestinationURL(
            in: dir,
            desiredBaseName: "borrowbox-dashboard",
            extension: "png",
            currentIdentity: meta1.identity
        )
        XCTAssertEqual(resolvedSelf.lastPathComponent, "borrowbox-dashboard.png")
    }

    func testSafeRenameFile() throws {
        let fileA = tempDir.appendingPathComponent("fileA.png")
        let fileB = tempDir.appendingPathComponent("fileB.png")
        try "hello".write(to: fileA, atomically: true, encoding: .utf8)

        // Normal rename
        try FilenameSanitizer.safeRenameFile(from: fileA, to: fileB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))

        // Existing destination throws
        let fileC = tempDir.appendingPathComponent("fileC.png")
        try "world".write(to: fileC, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FilenameSanitizer.safeRenameFile(from: fileC, to: fileB)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, CocoaError.fileWriteFileExists)
        }
    }

    // MARK: - End-to-End Worker Engine Tests

    func testWorkerEngineEndToEndSmartNamingBoth() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 12.00.00 PM.png")
        try "mock screenshot content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.smartNamingApplyTo = .both
        settings.uploadDelay = .asap
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "revenuecat-trial-customer-details",
                    title: "RevenueCat Trial Customer Details",
                    description: "Details for trial customer"
                )
            )
        )

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let now = Date().addingTimeInterval(10)
        let status = await engine.run(now: now)

        XCTAssertEqual(status.health, WorkerStatus.Health.ok)
        XCTAssertEqual(mockNamer.invokedURLs.count, 1)
        XCTAssertTrue(mockNamer.batchFinished)

        // Check local file was safely renamed
        let renamedURL = screenshotsDir.appendingPathComponent("revenuecat-trial-customer-details.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // Check Raindrop API upload used the renamed file
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)
        XCTAssertEqual(mockAPI.uploadedFiles.first?.lastPathComponent, "revenuecat-trial-customer-details.png")

        // Check metadata update passed generated title and excerpt
        XCTAssertEqual(mockAPI.updatedMetadata.count, 1)
        XCTAssertEqual(mockAPI.updatedMetadata.first?.title, "RevenueCat Trial Customer Details")
        XCTAssertEqual(mockAPI.updatedMetadata.first?.excerpt, "Details for trial customer")

        // Check persisted state
        let loadedState = StateStore.load(paths, now: now).state
        XCTAssertEqual(loadedState.records.count, 1)
        let record = loadedState.records[0]
        XCTAssertEqual(record.state, ShotState.uploaded)
        XCTAssertTrue(record.smartNamingAttempted)
        XCTAssertEqual(record.generatedFilename, "revenuecat-trial-customer-details")
        XCTAssertEqual(record.generatedTitle, "RevenueCat Trial Customer Details")
        XCTAssertEqual(record.generatedDescription, "Details for trial customer")
        XCTAssertEqual(record.modelStatus, "success")
        XCTAssertEqual(URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path, renamedURL.resolvingSymlinksInPath().path)
    }

    func testWorkerEngineSmartNamingRaindropOnly() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 1.00.00 PM.png")
        try "mock screenshot content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.smartNamingApplyTo = .raindropOnly
        settings.uploadDelay = .asap
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "figma-ios-settings-screen",
                    title: "Figma iOS Settings Screen",
                    description: "Figma mobile settings UI design"
                )
            )
        )

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let now = Date().addingTimeInterval(10)
        let status = await engine.run(now: now)

        XCTAssertEqual(status.health, WorkerStatus.Health.ok)

        // Local file should NOT be renamed
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Raindrop upload used original local file
        XCTAssertEqual(mockAPI.uploadedFiles.first?.resolvingSymlinksInPath().path, fileURL.resolvingSymlinksInPath().path)

        // Metadata update DID receive generated title and excerpt
        XCTAssertEqual(mockAPI.updatedMetadata.first?.title, "Figma iOS Settings Screen")
        XCTAssertEqual(mockAPI.updatedMetadata.first?.excerpt, "Figma mobile settings UI design")
    }

    func testWorkerEngineSmartNamingLocalOnly() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 2.00.00 PM.png")
        try "mock screenshot content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.smartNamingApplyTo = .localOnly
        settings.uploadDelay = .asap
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "apple-intelligence-docs",
                    title: "Apple Intelligence Documentation",
                    description: "Documentation page"
                )
            )
        )

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let now = Date().addingTimeInterval(10)
        let status = await engine.run(now: now)

        XCTAssertEqual(status.health, WorkerStatus.Health.ok)

        // Local file was renamed
        let renamedURL = screenshotsDir.appendingPathComponent("apple-intelligence-docs.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))

        // Raindrop metadata title fell back to local filename (because smart naming applies to local only)
        XCTAssertEqual(mockAPI.updatedMetadata.first?.title, "apple-intelligence-docs.png")
    }

    func testWorkerEngineSmartNamingDisabled() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 3.00.00 PM.png")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .off
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService()

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let now = Date().addingTimeInterval(10)
        _ = await engine.run(now: now)

        XCTAssertEqual(mockNamer.invokedURLs.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testWorkerEngineSmartNamingFailureFallback() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 4.00.00 PM.png")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .failure(NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model timeout"]))
        )

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let now = Date().addingTimeInterval(10)
        let status = await engine.run(now: now)

        // Upload must succeed despite AI failure!
        XCTAssertEqual(status.health, WorkerStatus.Health.ok)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let state = StateStore.load(paths, now: now).state
        XCTAssertEqual(state.records.first?.state, ShotState.uploaded)
        XCTAssertTrue(state.records.first?.smartNamingAttempted ?? false)
        XCTAssertEqual(state.records.first?.modelStatus, "Model timeout")
    }

    func testWorkerEngineSmartNamingIdempotentOnRetry() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 5.00.00 PM.png")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.smartNamingApplyTo = .both
        try settings.save(to: paths)

        // First upload fails with network error
        let mockAPI = MockRaindropAPI(
            uploadResult: .failure(.serverError(statusCode: 500))
        )
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "borrowbox-dashboard",
                    title: "BorrowBox Dashboard",
                    description: "Dashboard overview"
                )
            )
        )

        let engine1 = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let time1 = Date().addingTimeInterval(10)
        _ = await engine1.run(now: time1)

        XCTAssertEqual(mockNamer.invokedURLs.count, 1)

        // Second run: retry after backoff
        mockAPI.uploadResult = .success(
            UploadResponse.UploadItem(_id: 777, link: "https://raindrop.io/777", title: "Test", collectionId: nil)
        )

        let engine2 = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        let time2 = time1.addingTimeInterval(120) // Advance past backoff
        _ = await engine2.run(now: time2)

        // Mock namer MUST NOT have been called again!
        XCTAssertEqual(mockNamer.invokedURLs.count, 1)

        let state = StateStore.load(paths, now: time2).state
        XCTAssertEqual(state.records.first?.state, ShotState.uploaded)
        XCTAssertEqual(state.records.first?.raindropId, 777)
    }

    func testWorkerEngineSmartNamingTimingRespectsUploadDelay() async throws {
        let fileURL = screenshotsDir.appendingPathComponent("Screenshot 2026-10-08 at 6.00.00 PM.png")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        var settings = Settings(screenshotFolder: screenshotsDir.path)
        settings.smartNaming = .onDevice
        settings.uploadDelay = .fifteenMinutes // 900 seconds delay
        try settings.save(to: paths)

        let mockAPI = MockRaindropAPI()
        let mockNamer = MockScreenshotNamingService(
            metadataResult: .success(
                ScreenshotMetadata(
                    filename: "code-screen-logic",
                    title: "Code Screen Logic",
                    description: "Screenshot of Swift code"
                )
            )
        )

        let engine = WorkerEngine(
            paths: paths,
            api: mockAPI,
            keychain: keychain,
            detector: ScreenshotDetector(),
            namer: mockNamer
        )

        // 1. Initial scan immediately after creation (upload delay has NOT elapsed)
        let initialTime = Date().addingTimeInterval(5)
        _ = await engine.run(now: initialTime)

        // Must NOT run inference on discovered screenshot while waiting for delay!
        XCTAssertEqual(mockNamer.invokedURLs.count, 0)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 0)

        let state1 = StateStore.load(paths, now: initialTime).state
        XCTAssertEqual(state1.records.count, 1)
        XCTAssertEqual(state1.records.first?.state, ShotState.pending)
        XCTAssertFalse(state1.records.first?.smartNamingAttempted ?? true)

        // 2. Advance time past the 15-minute upload delay
        let eligibleTime = initialTime.addingTimeInterval(950)
        _ = await engine.run(now: eligibleTime)

        // Now that it became eligible for upload, inference ran immediately before upload!
        XCTAssertEqual(mockNamer.invokedURLs.count, 1)
        XCTAssertEqual(mockAPI.uploadedFiles.count, 1)

        let state2 = StateStore.load(paths, now: eligibleTime).state
        XCTAssertEqual(state2.records.first?.state, ShotState.uploaded)
        XCTAssertTrue(state2.records.first?.smartNamingAttempted ?? false)
    }

    func testSettingsSmartNamingSerializationRoundTrip() throws {
        var original = Settings(screenshotFolder: "/Users/test/Screenshots")
        original.smartNaming = .onDevice
        original.smartNamingApplyTo = .raindropOnly
        original.smartNamingOnlyOnPower = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(decoded.smartNaming, .onDevice)
        XCTAssertEqual(decoded.smartNamingApplyTo, .raindropOnly)
        XCTAssertEqual(decoded.smartNamingOnlyOnPower, true)
    }

    func testShotRecordSmartNamingSerializationRoundTrip() throws {
        let record = ShotRecord(
            path: "/path/to/test.png",
            identity: FileIdentity(device: 1, inode: 2),
            size: 1024,
            modifiedNanos: 500,
            capturedAt: Date(),
            detectedAt: Date(),
            state: .uploaded,
            smartNamingAttempted: true,
            generatedFilename: "smart-filename",
            generatedTitle: "Smart Title",
            generatedDescription: "Smart Description",
            modelStatus: "success"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ShotRecord.self, from: data)

        XCTAssertEqual(decoded.smartNamingAttempted, true)
        XCTAssertEqual(decoded.generatedFilename, "smart-filename")
        XCTAssertEqual(decoded.generatedTitle, "Smart Title")
        XCTAssertEqual(decoded.generatedDescription, "Smart Description")
        XCTAssertEqual(decoded.modelStatus, "success")
    }
}
