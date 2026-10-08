import Foundation
import Darwin
import os.log

public struct WorkerEngineOptions: Sendable {
    public var dryRun: Bool
    public var forceUploadNow: Bool
    public var verbose: Bool

    public init(dryRun: Bool = false, forceUploadNow: Bool = false, verbose: Bool = false) {
        self.dryRun = dryRun
        self.forceUploadNow = forceUploadNow
        self.verbose = verbose
    }
}

public final class WorkerEngine: @unchecked Sendable {
    private let paths: AppPaths
    private let api: RaindropAPIType
    private let keychain: any KeychainProtocol
    private let detector: ScreenshotDetector
    private let notificationMgr: NotificationManager
    private let namer: any ScreenshotNamingType
    private let processor: ScreenshotProcessor
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "Worker")

    public init(
        paths: AppPaths = .standard,
        api: RaindropAPIType = RaindropAPI(),
        keychain: any KeychainProtocol = KeychainHelper(),
        detector: ScreenshotDetector = ScreenshotDetector(),
        notificationMgr: NotificationManager? = nil,
        namer: (any ScreenshotNamingType)? = nil,
        processor: ScreenshotProcessor? = nil
    ) {
        self.paths = paths
        self.api = api
        self.keychain = keychain
        self.detector = detector
        self.notificationMgr = notificationMgr ?? NotificationManager(paths: paths)
        let resolvedNamer = namer ?? AppleFoundationModelsNamingService()
        self.namer = resolvedNamer
        self.processor = processor ?? ScreenshotProcessor(paths: paths, api: api, namer: resolvedNamer, detector: detector)
    }

    /// Single execution unit: wake up -> scan -> upload -> cleanup -> persist -> notify -> exit.
    @discardableResult
    public func run(options: WorkerEngineOptions = WorkerEngineOptions(), now: Date = Date()) async -> WorkerStatus {
        try? paths.ensureDirectory()

        // 1. Concurrency control via file lock
        let lockFd = FileOperations.tryLock(at: paths.workerLock)
        guard lockFd >= 0 else {
            logger.info("Another worker is currently active. Exiting immediately.")
            return WorkerStatus.load(from: paths) ?? WorkerStatus(updatedAt: now)
        }
        defer { FileOperations.unlock(fd: lockFd) }

        // 2. Load settings
        guard let settings = Settings.load(from: paths) else {
            logger.error("No settings found. Worker cannot run until setup is completed.")
            var status = WorkerStatus(updatedAt: now)
            status.health = .needsSetup
            status.message = "Setup required: Open settings to configure"
            try? JSONStore.write(status, to: paths.status)
            postStatusChangeNotification()
            return status
        }

        // Check if paused
        if settings.paused {
            logger.info("Sync is currently paused.")
            var status = WorkerStatus(updatedAt: now)
            status.health = .paused
            status.message = "Paused"
            try? JSONStore.write(status, to: paths.status)
            postStatusChangeNotification()
            return status
        }

        // 3. Load or initialize state
        var workerState = StateStore.load(paths, now: now).state
        workerState.lastRunAt = now

        // Check for manual "Upload now" request trigger file
        let hasUploadNowRequest = FileManager.default.fileExists(atPath: paths.uploadNowRequest.path)
        let isUploadNow = options.forceUploadNow || hasUploadNowRequest
        if hasUploadNowRequest && !options.dryRun {
            try? FileManager.default.removeItem(at: paths.uploadNowRequest)
        }

        // Check rate-limiting backoff
        if let rateLimitEnd = workerState.rateLimitedUntil, now < rateLimitEnd {
            logger.info("Rate limit backoff active until \(rateLimitEnd).")
            let status = buildStatus(state: workerState, settings: settings, now: now, message: "Rate limited until \(formatDate(rateLimitEnd))")
            persistStatusAndNotify(status: status, state: workerState)
            return status
        } else {
            workerState.rateLimitedUntil = nil
        }

        // 4. Verify screenshot directory
        let folderURL = settings.folderURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            logger.error("Configured screenshot folder does not exist: \(folderURL.path)")
            workerState.lastError = "Folder not found: \(folderURL.path)"
            var status = buildStatus(state: workerState, settings: settings, now: now, message: "Folder missing: \(folderURL.lastPathComponent)")
            status.health = .folderMissing
            persistStatusAndNotify(status: status, state: workerState)
            return status
        }

        // 5. Scan folder and update records
        scanAndReconcileFolder(folderURL: folderURL, settings: settings, state: &workerState, now: now)

        // 6. Check credentials
        let token = (try? keychain.readToken()) ?? ""
        if token.isEmpty {
            logger.error("Raindrop access token not found in Keychain.")
            workerState.lastError = "Authentication token missing"
            var status = buildStatus(state: workerState, settings: settings, now: now, message: "Authentication required")
            status.health = .authRequired
            persistStatusAndNotify(status: status, state: workerState)
            return status
        }

        // If auth previously failed for the current token generation, check backoff
        if let authFailure = workerState.auth, authFailure.generation == settings.tokenGeneration {
            let backoff = min(3600.0, pow(2.0, Double(min(authFailure.notified ? 5 : 1, 6))) * 60.0)
            if now.timeIntervalSince(authFailure.lastCheckedAt) < backoff && !isUploadNow {
                var status = buildStatus(state: workerState, settings: settings, now: now, message: "Authentication failed. Check token in settings.")
                status.health = .authRequired
                persistStatusAndNotify(status: status, state: workerState)
                return status
            }
        }

        // 7. Process pending uploads
        var uploadedBatchCount = 0
        await processPendingUploads(
            state: &workerState,
            settings: settings,
            token: token,
            isUploadNow: isUploadNow,
            options: options,
            uploadedBatchCount: &uploadedBatchCount,
            now: now
        )

        // 8. Process due local cleanup
        processDueCleanup(
            state: &workerState,
            settings: settings,
            options: options,
            now: now
        )

        // 9. Prune stale history
        pruneTerminalRecords(state: &workerState, now: now)

        // 10. Persist state
        if !options.dryRun {
            try? StateStore.save(workerState, paths)
        }

        // Notify if batch uploaded and user opted in
        if uploadedBatchCount > 0 && settings.notifyOnSuccess {
            let msg = uploadedBatchCount == 1 ? "1 screenshot uploaded" : "\(uploadedBatchCount) screenshots uploaded"
            notificationMgr.notify(title: "Raindrop.io Synced", body: msg, category: "success")
        }

        // 11. Write status snapshot and post notification
        let finalStatus = buildStatus(state: workerState, settings: settings, now: now)
        persistStatusAndNotify(status: finalStatus, state: workerState)

        // 12. Release any session held during the batch
        await namer.finishBatch()

        return finalStatus
    }

    /// Immediately cleans up all screenshots that have been confirmed uploaded to Raindrop.
    /// Bypasses retention wait. Uses configured cleanup action (or Trash).
    @discardableResult
    public func cleanUploadedNow() async -> Int {
        try? paths.ensureDirectory()
        let lockFd = FileOperations.tryLock(at: paths.workerLock)
        guard lockFd >= 0 else {
            logger.warning("Worker lock held. Skipping immediate cleanup.")
            return 0
        }
        defer { FileOperations.unlock(fd: lockFd) }

        let settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
        let now = Date()
        var workerState = StateStore.load(paths, now: now).state

        var cleanedCount = 0
        let action: CleanupAction = (settings.cleanupAction == .keep) ? .trash : settings.cleanupAction

        for i in 0..<workerState.records.count {
            var record = workerState.records[i]
            guard record.state == .uploaded else { continue }

            let fileURL = URL(fileURLWithPath: record.path)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                record.state = .missing
                record.finishedAt = now
                workerState.records[i] = record
                continue
            }

            // If modified locally after upload, do not delete
            if let meta = FileOperations.metadata(for: fileURL), meta.modifiedNanos != record.modifiedNanos {
                record.state = .kept
                record.finishedAt = now
                workerState.records[i] = record
                logger.info("File modified locally after upload. Skipping cleanup: \(record.fileName)")
                continue
            }

            do {
                try FileOperations.performCleanup(url: fileURL, action: action)
                record.state = .cleaned
                record.finishedAt = now
                workerState.records[i] = record
                cleanedCount += 1
                logger.info("Immediately cleaned up (\(action.title)): \(record.fileName)")
            } catch {
                logger.error("Failed to clean up \(record.fileName): \(error.localizedDescription)")
            }
        }

        pruneTerminalRecords(state: &workerState, now: now)
        try? StateStore.save(workerState, paths)

        let msg = cleanedCount > 0 ? "Cleaned up \(cleanedCount) screenshot\(cleanedCount == 1 ? "" : "s")" : "Synced"
        let status = buildStatus(state: workerState, settings: settings, now: now, message: msg)
        persistStatusAndNotify(status: status, state: workerState)

        return cleanedCount
    }

    // MARK: - Folder Scanning & Reconciling

    private func scanAndReconcileFolder(
        folderURL: URL,
        settings: Settings,
        state: inout WorkerState,
        now: Date
    ) {
        let items = FileOperations.listDirectoryItems(at: folderURL)
        var seenIdentities = Set<FileIdentity>()
        var pathToIdentity = [String: FileIdentity]()

        for itemURL in items {
            // Check if it's a screenshot candidate
            guard detector.isScreenshot(url: itemURL, mode: settings.detection) else {
                continue
            }

            guard let meta = FileOperations.metadata(for: itemURL) else {
                continue
            }

            seenIdentities.insert(meta.identity)
            pathToIdentity[itemURL.path] = meta.identity

            // Check if we already have this file tracked
            if let index = state.records.firstIndex(where: { $0.identity == meta.identity }) {
                var existing = state.records[index]

                // If path changed (e.g. renamed), update path
                if existing.path != itemURL.path {
                    existing.path = itemURL.path
                }

                // If modified after upload, mark kept so user's edits are never deleted!
                if existing.state == .uploaded && meta.modifiedNanos != existing.modifiedNanos {
                    existing.state = .kept
                    existing.finishedAt = now
                    logger.info("Screenshot was edited after upload. Preserving locally: \(itemURL.lastPathComponent)")
                } else if existing.state == .pending {
                    // Update size/mtime if still pending
                    existing.size = meta.size
                    existing.modifiedNanos = meta.modifiedNanos
                }

                state.records[index] = existing
            } else {
                // New screenshot discovered!
                // Don't track files created BEFORE the tracking baseline to prevent surprise legacy uploads
                if meta.capturedAt < state.trackingSince {
                    continue
                }

                let record = ShotRecord(
                    path: itemURL.path,
                    identity: meta.identity,
                    size: meta.size,
                    modifiedNanos: meta.modifiedNanos,
                    capturedAt: meta.capturedAt,
                    detectedAt: now,
                    state: .pending
                )
                state.records.append(record)
                logger.info("Discovered new screenshot: \(itemURL.lastPathComponent)")

                if settings.copyScreenshotToClipboard {
                    FileOperations.copyImageToClipboard(at: itemURL)
                    logger.info("Copied screenshot image to clipboard: \(itemURL.lastPathComponent)")
                }
            }
        }

        // Reconcile missing files: if a file is in state as pending or uploaded, but no longer exists on disk
        for i in 0..<state.records.count {
            let rec = state.records[i]
            if !rec.state.isTerminal && !seenIdentities.contains(rec.identity) {
                // Double check if file at path exists
                if !FileManager.default.fileExists(atPath: rec.path) {
                    state.records[i].state = .missing
                    state.records[i].finishedAt = now
                    logger.info("Screenshot no longer found on disk: \(rec.fileName)")
                }
            }
        }
    }

    // MARK: - Upload Processing

    private func processPendingUploads(
        state: inout WorkerState,
        settings: Settings,
        token: String,
        isUploadNow: Bool,
        options: WorkerEngineOptions,
        uploadedBatchCount: inout Int,
        now: Date
    ) async {
        // Collect eligible pending records
        for i in 0..<state.records.count {
            var record = state.records[i]
            guard record.state.isAwaitingUpload else { continue }

            let fileURL = URL(fileURLWithPath: record.path)

            // Stability check: file must be stable (finished writing)
            guard detector.isFileStable(url: fileURL, now: now) else {
                logger.info("Skipping fresh/unstable file until next run: \(record.fileName)")
                continue
            }

            // Upload delay check (unless manual "Upload now" triggered)
            if !isUploadNow {
                if settings.uploadDelay == .manual {
                    // Manual only: don't upload automatically
                    continue
                }

                if let delayInterval = settings.uploadDelay.interval {
                    let eligibleTime = record.capturedAt.addingTimeInterval(delayInterval)
                    if now < eligibleTime {
                        logger.debug("Upload delay not yet reached for \(record.fileName). Eligible at: \(eligibleTime)")
                        continue
                    }
                }

                // Check retry backoff
                if let nextRetry = record.nextRetryAt, now < nextRetry {
                    logger.debug("Retry backoff not yet elapsed for \(record.fileName). Next retry: \(nextRetry)")
                    continue
                }
            }

            // Perform upload
            if options.dryRun {
                logger.info("[Dry Run] Would upload: \(record.fileName)")
                continue
            }

            logger.info("Uploading: \(record.fileName) (attempt \(record.attempts + 1))")

            let result = await processor.processItem(
                record: &record,
                settings: settings,
                token: token,
                now: now
            )

            switch result {
            case .uploaded:
                state.records[i] = record
                state.lastUploadAt = now
                state.auth = nil
                state.offlineSince = nil
                uploadedBatchCount += 1
                try? StateStore.save(state, paths)

            case .authRequired:
                handleUploadError(
                    error: .unauthorized,
                    record: &record,
                    state: &state,
                    settings: settings,
                    now: now
                )
                state.records[i] = record
                try? StateStore.save(state, paths)
                return

            case .offline:
                handleUploadError(
                    error: .offline(message: "Device appears offline"),
                    record: &record,
                    state: &state,
                    settings: settings,
                    now: now
                )
                state.records[i] = record
                try? StateStore.save(state, paths)
                return

            case .rateLimited(let delay):
                handleUploadError(
                    error: .rateLimited(retryAfter: delay),
                    record: &record,
                    state: &state,
                    settings: settings,
                    now: now
                )
                state.records[i] = record
                try? StateStore.save(state, paths)
                return

            case .rejected(let msg):
                handleUploadError(
                    error: .rejected(message: msg),
                    record: &record,
                    state: &state,
                    settings: settings,
                    now: now
                )
                state.records[i] = record
                try? StateStore.save(state, paths)

            case .powerRestricted:
                state.records[i] = record
                try? StateStore.save(state, paths)

            case .skipped(let reason):
                logger.info("Skipped \(record.fileName): \(reason)")
                state.records[i] = record
                try? StateStore.save(state, paths)

            case .retryableFailure(let error, _):
                if let apiError = error as? RaindropAPIError {
                    handleUploadError(
                        error: apiError,
                        record: &record,
                        state: &state,
                        settings: settings,
                        now: now
                    )
                } else {
                    let attempts = record.attempts
                    let fileName = record.fileName
                    if attempts >= 5 && !record.failureNotified {
                        notificationMgr.notify(
                            title: "Upload Failing Repeatedly",
                            body: "Failed \(attempts) times to upload \(fileName).",
                            category: "failing"
                        )
                        record.failureNotified = true
                    }
                }
                state.records[i] = record
                try? StateStore.save(state, paths)
            }
        }
    }

    private func handleUploadError(
        error: RaindropAPIError,
        record: inout ShotRecord,
        state: inout WorkerState,
        settings: Settings,
        now: Date
    ) {
        let fileName = record.fileName
        let attempts = record.attempts
        logger.error("Upload error for \(fileName): \(error.localizedDescription)")
        record.lastError = error.localizedDescription

        switch error {
        case .unauthorized:
            record.state = .pending
            let prevAuth = state.auth
            state.auth = AuthFailure(
                failedAt: prevAuth?.failedAt ?? now,
                generation: settings.tokenGeneration,
                lastCheckedAt: now,
                notified: prevAuth?.notified ?? false
            )
            if state.auth?.notified != true {
                notificationMgr.notify(
                    title: "Raindrop Authentication Failed",
                    body: "Please update your API token in RaindropShot settings.",
                    category: "auth"
                )
                state.auth?.notified = true
            }

        case .rateLimited(let retryAfter):
            record.state = .pending
            let delay = retryAfter ?? 60.0
            state.rateLimitedUntil = now.addingTimeInterval(delay)
            record.nextRetryAt = state.rateLimitedUntil

        case .rejected(let msg):
            // Permanent rejection (corrupt file, too large, etc.) - never retry or delete!
            record.state = .rejected
            record.finishedAt = now
            record.lastError = msg
            notificationMgr.notify(
                title: "Upload Rejected",
                body: "Raindrop rejected \(fileName): \(msg)",
                category: "rejected"
            )

        case .offline(let msg):
            record.state = .pending
            state.offlineSince = now
            let backoff = calculateBackoff(attempts: attempts)
            let retryDate = now.addingTimeInterval(backoff)
            record.nextRetryAt = retryDate
            logger.info("Offline: \(msg). Will retry at \(retryDate)")

        case .serverError(let code):
            record.state = .pending
            let backoff = calculateBackoff(attempts: attempts)
            let retryDate = now.addingTimeInterval(backoff)
            record.nextRetryAt = retryDate
            logger.info("Server error (\(code)). Will retry at \(retryDate)")

        default:
            record.state = .pending
            let backoff = calculateBackoff(attempts: attempts)
            record.nextRetryAt = now.addingTimeInterval(backoff)
        }

        // If failing repeatedly (>= 5 times) and not yet notified
        if attempts >= 5 && !record.failureNotified {
            notificationMgr.notify(
                title: "Upload Failing Repeatedly",
                body: "Failed \(attempts) times to upload \(fileName).",
                category: "failing"
            )
            record.failureNotified = true
        }
    }

    // MARK: - Due Local Cleanup

    private func processDueCleanup(
        state: inout WorkerState,
        settings: Settings,
        options: WorkerEngineOptions,
        now: Date
    ) {
        ScreenshotProcessor.processDueCleanup(
            state: &state,
            settings: settings,
            dryRun: options.dryRun,
            now: now
        )
    }

    // MARK: - History Pruning

    private func pruneTerminalRecords(state: inout WorkerState, now: Date) {
        let maxAge: TimeInterval = 7 * 86_400 // 7 days
        let maxRecords = 300

        state.records.removeAll { rec in
            guard rec.state.isTerminal, let finished = rec.finishedAt else {
                return false
            }
            return now.timeIntervalSince(finished) > maxAge
        }

        // If still exceeding cap, remove oldest terminal records
        if state.records.count > maxRecords {
            let terminalIndices = state.records.indices.filter { state.records[$0].state.isTerminal }
            let excess = state.records.count - maxRecords
            let toRemove = terminalIndices.prefix(excess)
            for index in toRemove.reversed() {
                state.records.remove(at: index)
            }
        }
    }

    // MARK: - Status Snapshot & Notification

    private func buildStatus(
        state: WorkerState,
        settings: Settings,
        now: Date,
        message: String? = nil
    ) -> WorkerStatus {
        var status = WorkerStatus(updatedAt: now)
        status.phase = .idle
        status.lastRunAt = state.lastRunAt
        status.lastUploadAt = state.lastUploadAt

        status.pending = state.records.filter { $0.state.isAwaitingUpload }.count
        status.failing = state.records.filter { $0.state == .rejected || ($0.state == .pending && $0.attempts > 0) }.count
        status.awaitingCleanup = state.records.filter { $0.state == .uploaded }.count

        // Find next retry
        let pendingRetries = state.records.compactMap { $0.nextRetryAt }.filter { $0 > now }
        status.nextRetryAt = pendingRetries.min()

        if let msg = message {
            status.message = msg
        } else if let auth = state.auth, auth.generation == settings.tokenGeneration {
            status.health = .authRequired
            status.message = "Authentication required"
        } else if state.offlineSince != nil {
            status.health = .offline
            status.message = "Offline"
        } else if status.failing > 0 {
            status.health = .error
            status.message = "\(status.failing) failed"
        } else if status.pending > 0 {
            status.health = .ok
            status.message = "\(status.pending) pending"
        } else {
            status.health = .ok
            status.message = "Synced"
        }

        return status
    }

    private func persistStatusAndNotify(status: WorkerStatus, state: WorkerState) {
        try? JSONStore.write(status, to: paths.status)
        postStatusChangeNotification()
    }

    private func postStatusChangeNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(AppIdentity.statusNotification as CFString), nil, nil, true)
    }

    private func calculateBackoff(attempts: Int) -> TimeInterval {
        let base: Double = 30.0
        let multiplier = pow(2.0, Double(min(attempts, 6)))
        return min(1800.0, base * multiplier)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
