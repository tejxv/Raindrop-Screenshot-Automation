import XCTest
@testable import RaindropShotCore

final class UploadDelayAndRetentionTests: XCTestCase {
    func testUploadDelayIntervals() {
        XCTAssertEqual(UploadDelay.asap.interval, 0)
        XCTAssertEqual(UploadDelay.fiveMinutes.interval, 300)
        XCTAssertEqual(UploadDelay.fifteenMinutes.interval, 900)
        XCTAssertEqual(UploadDelay.thirtyMinutes.interval, 1800)
        XCTAssertEqual(UploadDelay.oneHour.interval, 3600)
        XCTAssertNil(UploadDelay.manual.interval)
    }

    func testRetentionIntervals() {
        XCTAssertEqual(Retention.fiveMinutes.interval, 300)
        XCTAssertEqual(Retention.fifteenMinutes.interval, 900)
        XCTAssertEqual(Retention.oneHour.interval, 3600)
        XCTAssertEqual(Retention.oneDay.interval, 86400)
        XCTAssertEqual(Retention.sevenDays.interval, 604800)
        XCTAssertNil(Retention.never.interval)
    }

    func testEffectiveRetention() {
        var settings = Settings(screenshotFolder: "/tmp")
        settings.retention = .fiveMinutes
        settings.cleanupAction = .trash
        XCTAssertEqual(settings.effectiveRetention, 300)

        // When cleanupAction is .keep, effectiveRetention is nil (never delete)
        settings.cleanupAction = .keep
        XCTAssertNil(settings.effectiveRetention)

        // When retention is .never, effectiveRetention is nil
        settings.cleanupAction = .trash
        settings.retention = .never
        XCTAssertNil(settings.effectiveRetention)
    }

    func testUploadEligibilityCalculation() {
        let captureTime = Date(timeIntervalSince1970: 1000)

        // 1. ASAP is immediately eligible
        let asapDelay = UploadDelay.asap.interval!
        XCTAssertTrue(Date(timeIntervalSince1970: 1000) >= captureTime.addingTimeInterval(asapDelay))

        // 2. 5 min delay: not eligible at 1200 (200s < 300s), eligible at 1300 (300s)
        let fiveMinDelay = UploadDelay.fiveMinutes.interval!
        XCTAssertFalse(Date(timeIntervalSince1970: 1200) >= captureTime.addingTimeInterval(fiveMinDelay))
        XCTAssertTrue(Date(timeIntervalSince1970: 1300) >= captureTime.addingTimeInterval(fiveMinDelay))
        XCTAssertTrue(Date(timeIntervalSince1970: 1500) >= captureTime.addingTimeInterval(fiveMinDelay))
    }

    func testCleanupEligibilityCalculation() {
        let uploadTime = Date(timeIntervalSince1970: 2000)
        let retention = Retention.fiveMinutes.interval! // 300s

        // Before 2300: local screenshot remains untouched
        XCTAssertFalse(Date(timeIntervalSince1970: 2100) >= uploadTime.addingTimeInterval(retention))
        XCTAssertFalse(Date(timeIntervalSince1970: 2299) >= uploadTime.addingTimeInterval(retention))

        // At or after 2300: cleanup becomes eligible
        XCTAssertTrue(Date(timeIntervalSince1970: 2300) >= uploadTime.addingTimeInterval(retention))
        XCTAssertTrue(Date(timeIntervalSince1970: 2500) >= uploadTime.addingTimeInterval(retention))
    }
}
