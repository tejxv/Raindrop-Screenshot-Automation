import Foundation
import os.log

public enum ProcessItemResult: Sendable {
    case uploaded(item: UploadResponse.UploadItem)
    case skipped(reason: String)
    case retryableFailure(error: Error, nextRetryAt: Date)
    case authRequired
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case powerRestricted
    case rejected(reason: String)
}

/// The canonical engine that executes the lifecycle steps for a single screenshot:
/// stability check -> smart naming -> safe rename -> upload -> raindrop metadata update -> finish.
/// Both normal background sync (`WorkerEngine`) and backlog sweep (`SweepCoordinator`)
/// share this exact pipeline.
public final class ScreenshotProcessor: @unchecked Sendable {
    private let paths: AppPaths
    private let api: RaindropAPIType
    private let namer: any ScreenshotNamingType
    private let detector: ScreenshotDetector
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "Processor")

    public init(
        paths: AppPaths = .standard,
        api: RaindropAPIType = RaindropAPI(),
        namer: any ScreenshotNamingType = AppleFoundationModelsNamingService(),
        detector: ScreenshotDetector = ScreenshotDetector()
    ) {
        self.paths = paths
        self.api = api
        self.namer = namer
        self.detector = detector
    }

    /// Processes one single screenshot through the canonical pipeline.
    public func processItem(
        record: inout ShotRecord,
        settings: Settings,
        token: String,
        now: Date,
        onPhaseChange: ((SweepStatus.Phase) -> Void)? = nil
    ) async -> ProcessItemResult {
        var fileURL = URL(fileURLWithPath: record.path)
        let initialFileName = record.fileName

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            record.state = .missing
            record.finishedAt = now
            return .skipped(reason: "File missing on disk")
        }

        // 1. Stability Check
        guard detector.isFileStable(url: fileURL, now: now) else {
            logger.info("File is not yet stable: \(initialFileName)")
            return .skipped(reason: "File is still being written")
        }

        // 2. Smart Naming (if enabled and not previously attempted)
        if settings.smartNaming == .onDevice && !record.smartNamingAttempted {
            if settings.smartNamingOnlyOnPower && !PowerSourceHelper.isOnACPower() {
                logger.info("Smart naming postponed: running on battery power for \(initialFileName)")
                return .powerRestricted
            }

            onPhaseChange?(.organizing)
            record.smartNamingAttempted = true
            let availability = namer.isAvailable()
            if availability.available {
                do {
                    let metadata = try await namer.generateMetadata(for: fileURL)
                    record.generatedFilename = metadata.filename
                    record.generatedTitle = metadata.title
                    record.generatedDescription = metadata.description
                    record.modelStatus = "success"
                    let genName = metadata.filename
                    logger.info("Smart naming generated for \(initialFileName): \(genName)")
                } catch {
                    let errStr = error.localizedDescription
                    record.modelStatus = errStr
                    logger.warning("Smart naming failed for \(initialFileName): \(errStr). Falling back to original filename.")
                }
            } else {
                let reason = availability.reason ?? "unavailable"
                record.modelStatus = reason
                logger.info("Smart naming unavailable (\(reason)). Falling back to original filename.")
            }
        }

        // 3. Safe Local Rename (if enabled and generated name is present)
        if settings.smartNamingApplyTo.appliesToLocalFile,
           let genName = record.generatedFilename,
           !genName.isEmpty {
            let parentDir = fileURL.deletingLastPathComponent()
            let origExt = fileURL.pathExtension
            let targetURL = FilenameSanitizer.resolveSafeDestinationURL(
                in: parentDir,
                desiredBaseName: genName,
                extension: origExt,
                currentIdentity: record.identity
            )

            if targetURL.path != fileURL.path {
                do {
                    try FilenameSanitizer.safeRenameFile(from: fileURL, to: targetURL)
                    let origName = fileURL.lastPathComponent
                    let newName = targetURL.lastPathComponent
                    logger.info("Renamed local screenshot: \(origName) -> \(newName)")
                    record.path = targetURL.path
                    fileURL = targetURL
                } catch {
                    let destName = targetURL.lastPathComponent
                    let errStr = error.localizedDescription
                    logger.warning("Failed to rename file to \(destName): \(errStr). Proceeding with original name.")
                }
            }
        }

        // 4. Upload to Raindrop
        onPhaseChange?(.uploading)
        record.state = .uploading
        record.lastAttemptAt = now
        record.attempts += 1

        do {
            let item = try await api.uploadFile(
                fileURL: fileURL,
                token: token,
                collectionId: settings.collectionId
            )

            // Upload confirmed!
            record.state = .uploaded
            record.uploadedAt = now
            record.raindropId = item._id
            record.raindropLink = item.link
            record.raindropCover = item.cover ?? ShotRecord.constructPublicCoverURL(id: item._id, fileName: record.fileName)
            record.lastError = nil
            record.nextRetryAt = nil

            if settings.copyLinkToClipboardOnUpload, let pubURL = record.publicURL {
                FileOperations.copyTextToClipboard(pubURL)
            }

            // 5. Update Raindrop Metadata (Title, Excerpt, Tags)
            let raindropTitle: String
            let raindropExcerpt: String?
            let defaultExcerpt = "Captured on \(formatDate(record.capturedAt))"
            if settings.smartNamingApplyTo.appliesToRaindrop, let genTitle = record.generatedTitle, !genTitle.isEmpty {
                raindropTitle = genTitle
                raindropExcerpt = record.generatedDescription ?? defaultExcerpt
            } else {
                raindropTitle = record.fileName
                raindropExcerpt = defaultExcerpt
            }

            let shouldUpdateMetadata = !settings.tags.isEmpty || (settings.smartNamingApplyTo.appliesToRaindrop && record.generatedTitle != nil)
            if shouldUpdateMetadata {
                try? await api.updateRaindropMetadata(
                    id: item._id,
                    token: token,
                    title: raindropTitle,
                    tags: settings.tags.isEmpty ? nil : settings.tags,
                    excerpt: raindropExcerpt
                )
            }

            let finalFileName = record.fileName
            let itemId = item._id
            logger.info("Successfully processed and uploaded \(finalFileName) -> ID: \(itemId)")
            return .uploaded(item: item)

        } catch let error as RaindropAPIError {
            switch error {
            case .unauthorized:
                record.state = .pending
                record.lastError = error.errorDescription
                return .authRequired

            case .offline:
                record.state = .pending
                record.lastError = error.errorDescription
                let backoff = calculateBackoff(attempts: record.attempts)
                record.nextRetryAt = now.addingTimeInterval(backoff)
                return .offline

            case .rateLimited(let delay):
                record.state = .pending
                record.lastError = error.errorDescription
                let backoff = delay ?? 60.0
                record.nextRetryAt = now.addingTimeInterval(backoff)
                return .rateLimited(retryAfter: delay)

            case .rejected(let msg):
                record.state = .rejected
                record.finishedAt = now
                record.lastError = msg
                return .rejected(reason: msg)

            case .serverError, .invalidResponse, .missingToken:
                record.state = .pending
                record.lastError = error.errorDescription
                let backoff = calculateBackoff(attempts: record.attempts)
                let retryDate = now.addingTimeInterval(backoff)
                record.nextRetryAt = retryDate
                return .retryableFailure(error: error, nextRetryAt: retryDate)
            }
        } catch {
            record.state = .pending
            record.lastError = error.localizedDescription
            let backoff = calculateBackoff(attempts: record.attempts)
            let retryDate = now.addingTimeInterval(backoff)
            record.nextRetryAt = retryDate
            return .retryableFailure(error: error, nextRetryAt: retryDate)
        }
    }

    private func calculateBackoff(attempts: Int) -> TimeInterval {
        let base = 5.0
        let exp = min(Double(attempts), 6.0)
        let backoff = base * pow(2.0, exp)
        let jitter = Double.random(in: 0.8...1.2)
        return min(backoff * jitter, 3600.0)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Canonical cleanup execution shared across background worker and backlog sweep.
    @discardableResult
    public static func processDueCleanup(
        state: inout WorkerState,
        settings: Settings,
        dryRun: Bool = false,
        now: Date
    ) -> Int {
        guard let retentionInterval = settings.effectiveRetention else {
            return 0
        }

        var cleanedCount = 0
        for i in 0..<state.records.count {
            var record = state.records[i]
            guard record.state == .uploaded, let uploadedAt = record.uploadedAt else {
                continue
            }

            let cleanupDueTime = uploadedAt.addingTimeInterval(retentionInterval)
            guard now >= cleanupDueTime else {
                continue
            }

            let fileURL = URL(fileURLWithPath: record.path)

            // Check if file still exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                record.state = .missing
                record.finishedAt = now
                state.records[i] = record
                continue
            }

            // Check if modified since upload
            if let meta = FileOperations.metadata(for: fileURL), meta.modifiedNanos != record.modifiedNanos {
                record.state = .kept
                record.finishedAt = now
                state.records[i] = record
                continue
            }

            if dryRun {
                continue
            }

            do {
                try FileOperations.performCleanup(url: fileURL, action: settings.cleanupAction)
                record.state = .cleaned
                record.finishedAt = now
                state.records[i] = record
                cleanedCount += 1
            } catch {
                // Ignore cleanup errors
            }
        }
        return cleanedCount
    }
}

