import XCTest
@testable import RaindropShotCore

final class ScreenshotDetectorTests: XCTestCase {
    private var detector: ScreenshotDetector!

    override func setUp() {
        super.setUp()
        detector = ScreenshotDetector()
    }

    func testStandardEnglishPrefixes() {
        let validNames = [
            "Screenshot 2026-10-07 at 10.30.00.png",
            "Screen Shot 2024-01-01 at 12.00.00.jpg",
            "Screenshot 2026-10-07 at 7.13.52 PM.jpeg"
        ]

        for name in validNames {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertTrue(detector.isScreenshot(url: url), "Expected \(name) to be recognized as screenshot")
        }
    }

    func testLocalizedPrefixes() {
        let localizedNames = [
            "Bildschirmfoto 2026-10-07 um 12.00.00.png", // German
            "Capture d’écran 2026-10-07 à 12.00.00.png", // French
            "Capture d'écran 2026-10-07 à 12.00.00.png", // French alt
            "Captura de pantalla 2026-10-07 a las 12.00.00.png", // Spanish
            "Istantanea 2026-10-07 alle 12.00.00.png", // Italian
            "Schermafbeelding 2026-10-07 om 12.00.00.png", // Dutch
            "Снимок экрана 2026-10-07 в 12.00.00.png", // Russian
            "スクリーンショット 2026-10-07 12.00.00.png", // Japanese
            "CleanShot 2026-10-07 at 12.00.00.png" // CleanShot
        ]

        for name in localizedNames {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertTrue(detector.isScreenshot(url: url), "Expected \(name) to be recognized as localized screenshot")
        }
    }

    func testNonScreenshotFilesIgnored() {
        let nonScreenshots = [
            "Document.pdf",
            "vacation_photo.jpg",
            "my_resume.png",
            "notes.txt",
            "Screenshot_archive.zip"
        ]

        for name in nonScreenshots {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertFalse(detector.isScreenshot(url: url), "Expected \(name) to NOT be recognized as screenshot")
        }
    }

    func testAllImagesMode() {
        let anyImage = URL(fileURLWithPath: "/tmp/vacation_photo.jpg")
        let nonImage = URL(fileURLWithPath: "/tmp/report.pdf")

        XCTAssertFalse(detector.isScreenshot(url: anyImage, mode: .screenshotsOnly))
        XCTAssertTrue(detector.isScreenshot(url: anyImage, mode: .allImages))
        XCTAssertFalse(detector.isScreenshot(url: nonImage, mode: .allImages))
    }

    func testFileStabilityCheck() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("Screenshot 2026-10-07.png")

        // 1. Zero-byte file is NOT stable
        FileManager.default.createFile(atPath: testFile.path, contents: Data())
        XCTAssertFalse(detector.isFileStable(url: testFile, now: Date()))

        // 2. Non-zero file modified 1 second ago with minimumAge 2.0 is NOT stable
        let sampleData = "PNGDATA".data(using: .utf8)!
        try sampleData.write(to: testFile)
        let freshTime = Date()
        XCTAssertFalse(detector.isFileStable(url: testFile, now: freshTime, minimumAge: 2.0))

        // 3. File aged 5 seconds IS stable
        let olderTime = freshTime.addingTimeInterval(5.0)
        XCTAssertTrue(detector.isFileStable(url: testFile, now: olderTime, minimumAge: 2.0))
    }
}
