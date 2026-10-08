import Foundation
import Darwin
import os.log

public final class SweepCoordinator: @unchecked Sendable {
    public struct CandidateMetadata: Sendable, Equatable {
        public let url: URL
        public let identity: FileIdentity
        public let size: Int64
        public let modifiedNanos: Int64
        public let capturedAt: Date

        public init(
            url: URL,
            identity: FileIdentity,
            size: Int64,
            modifiedNanos: Int64,
            capturedAt: Date
        ) {
            self.url = url
            self.identity = identity
            self.size = size
            self.modifiedNanos = modifiedNanos
            self.capturedAt = capturedAt
        }
    }

    private let paths: AppPaths
    private let api: RaindropAPIType
    private let keychain: any KeychainProtocol
    private let namer: any ScreenshotNamingType
    private let detector: ScreenshotDetector
    private let processor: ScreenshotProcessor
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "Sweep")

    private let stateLock = NSLock()
    private var _isPaused: Bool = false
    private var _isStopped: Bool = false

    public var isPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPaused
    }

    public var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isStopped
    }

    private func resetControlFlags() {
        stateLock.lock()
        _isStopped = false
        _isPaused = false
        stateLock.unlock()
    }

    public init(
        paths: AppPaths = .standard,
        api: RaindropAPIType = RaindropAPI(),
        keychain: any KeychainProtocol = KeychainHelper(),
        namer: any ScreenshotNamingType = AppleFoundationModelsNamingService(),
        detector: ScreenshotDetector = ScreenshotDetector(),
        processor: ScreenshotProcessor? = nil
    ) {
        self.paths = paths
        self.api = api
        self.keychain = keychain
        self.namer = namer
        self.detector = detector
        self.processor = processor ?? ScreenshotProcessor(paths: paths, api: api, namer: namer, detector: detector)
    }

    // MARK: - Candidate Discovery

    /// Cheaply discovers screenshots in `folderURL` that have not yet been handled into a terminal state.
    /// Orders results oldest-first.
    public static func discoverCandidates(
        folderURL: URL,
        state: WorkerState,
        detector: ScreenshotDetector = ScreenshotDetector()
    ) -> [CandidateMetadata] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        // Build index of identities and paths in state
        var terminalIdentities = Set<FileIdentity>()
        var terminalPaths = Set<String>()
        for rec in state.records {
            if rec.state.isTerminal || rec.state == .uploaded || rec.state == .rejected || rec.state == .missing {
                terminalIdentities.insert(rec.identity)
                terminalPaths.insert(rec.path)
            }
        }

        var candidates: [CandidateMetadata] = []

        for itemURL in items {
            guard detector.isScreenshot(url: itemURL) else {
                continue
            }

            guard let meta = FileOperations.metadata(for: itemURL) else {
                continue
            }

            // Exclude already processed/terminal records
            if terminalIdentities.contains(meta.identity) || terminalPaths.contains(itemURL.path) {
                continue
            }

            candidates.append(
                CandidateMetadata(
                    url: itemURL,
                    identity: meta.identity,
                    size: meta.size,
                    modifiedNanos: meta.modifiedNanos,
                    capturedAt: meta.capturedAt
                )
            )
        }

        // Sort oldest first
        candidates.sort { $0.capturedAt < $1.capturedAt }
        return candidates
    }

    // MARK: - Control Methods

    public func pause() {
        stateLock.lock()
        _isPaused = true
        stateLock.unlock()
    }

    public func resume() {
        stateLock.lock()
        _isPaused = false
        stateLock.unlock()
    }

    public func requestStop() {
        stateLock.lock()
        _isStopped = true
        stateLock.unlock()
        Self.requestStop(paths: paths)
    }

    public static func requestStop(paths: AppPaths) {
        try? paths.ensureDirectory()
        try? "".write(to: paths.sweepStopRequest, atomically: true, encoding: .utf8)
    }

    // MARK: - Execution

    @discardableResult
    public func runSweep(
        now: Date = Date(),
        onProgress: (@Sendable (SweepStatus) -> Void)? = nil
    ) async -> SweepStatus {
        try? paths.ensureDirectory()

        // 1. Lock concurrency
        let lockFd = FileOperations.tryLock(at: paths.sweepLock)
        guard lockFd >= 0 else {
            logger.info("Another sweep process is currently active. Exiting.")
            return SweepStatus.load(from: paths) ?? SweepStatus(state: .failed, message: "Sweep already running")
        }
        defer {
            FileOperations.unlock(fd: lockFd)
            if FileManager.default.fileExists(atPath: paths.sweepStopRequest.path) {
                try? FileManager.default.removeItem(at: paths.sweepStopRequest)
            }
            resetControlFlags()
        }

        // 2. Load settings
        guard let settings = Settings.load(from: paths) else {
            logger.error("No settings found for sweep.")
            var status = SweepStatus(state: .failed, message: "Setup required: Open settings to configure")
            persistAndNotify(status: &status, onProgress: onProgress)
            return status
        }

        // 3. Load token
        let token = (try? keychain.readToken()) ?? ""
        if token.isEmpty {
            logger.error("No Raindrop token found for sweep.")
            var status = SweepStatus(state: .authRequired, message: "Authentication required")
            persistAndNotify(status: &status, onProgress: onProgress)
            return status
        }

        // 4. Verify directory
        let folderURL = settings.folderURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            logger.error("Configured screenshot folder does not exist: \(folderURL.path)")
            var status = SweepStatus(state: .failed, message: "Folder missing: \(folderURL.lastPathComponent)")
            persistAndNotify(status: &status, onProgress: onProgress)
            return status
        }

        // 5. Load canonical state
        var workerState = StateStore.load(paths, now: now).state

        // 6. Discover candidates
        var status = SweepStatus(
            state: .running,
            phase: .discovering,
            startedAt: now,
            updatedAt: now
        )
        persistAndNotify(status: &status, onProgress: onProgress)

        let candidates = Self.discoverCandidates(folderURL: folderURL, state: workerState, detector: detector)
        if candidates.isEmpty {
            logger.info("Sweep found 0 eligible candidate screenshots.")
            status.total = 0
            status.completed = 0
            status.uploaded = 0
            status.state = .completed
            status.phase = .complete
            status.message = "No existing screenshots to organize."
            persistAndNotify(status: &status, onProgress: onProgress)
            return status
        }

        // Register candidates in WorkerState if not already present
        var registeredAny = false
        for candidate in candidates {
            if !workerState.records.contains(where: { $0.identity == candidate.identity || $0.path == candidate.url.path }) {
                let rec = ShotRecord(
                    path: candidate.url.path,
                    identity: candidate.identity,
                    size: candidate.size,
                    modifiedNanos: candidate.modifiedNanos,
                    capturedAt: candidate.capturedAt,
                    detectedAt: now,
                    state: .pending
                )
                workerState.records.append(rec)
                registeredAny = true
            }
        }

        if let oldest = candidates.map(\.capturedAt).min(), oldest < workerState.trackingSince {
            workerState.trackingSince = oldest
            registeredAny = true
        }

        if registeredAny {
            try? StateStore.save(workerState, paths)
        }

        // 7. Initialize status counters
        status.total = candidates.count
        status.completed = 0
        status.uploaded = 0
        status.skipped = 0
        status.failed = 0
        status.remaining = candidates.count
        status.phase = (settings.smartNaming == .onDevice ? .organizing : .uploading)
        persistAndNotify(status: &status, onProgress: onProgress)

        logger.info("Starting sweep for \(candidates.count) screenshots.")

        // 8. Process items sequentially
        for candidate in candidates {
            // Check stop condition
            if isStopped || FileManager.default.fileExists(atPath: paths.sweepStopRequest.path) {
                logger.info("Sweep stopped by user.")
                status.state = .stopped
                status.message = "Sweep stopped by user"
                persistAndNotify(status: &status, onProgress: onProgress)
                break
            }

            // Check pause condition
            while isPaused {
                status.state = .paused
                persistAndNotify(status: &status, onProgress: onProgress)
                try? await Task.sleep(nanoseconds: 300_000_000)
                if isStopped || FileManager.default.fileExists(atPath: paths.sweepStopRequest.path) {
                    break
                }
            }

            if isStopped || FileManager.default.fileExists(atPath: paths.sweepStopRequest.path) {
                status.state = .stopped
                status.message = "Sweep stopped by user"
                persistAndNotify(status: &status, onProgress: onProgress)
                break
            }

            status.state = .running

            // Find record in workerState
            guard let recordIndex = workerState.records.firstIndex(where: {
                $0.identity == candidate.identity || $0.path == candidate.url.path
            }) else {
                continue
            }

            var record = workerState.records[recordIndex]

            // If already in a terminal state or uploaded (e.g. from a parallel run), count as completed
            if record.state.isTerminal || record.state == .uploaded {
                status.completed += 1
                status.remaining = max(0, status.total - status.completed)
                persistAndNotify(status: &status, onProgress: onProgress)
                continue
            }

            // Check power restriction fallback:
            // "Smart naming must NEVER block screenshot syncing."
            var itemSettings = settings
            if settings.smartNaming == .onDevice && settings.smartNamingOnlyOnPower && !PowerSourceHelper.isOnACPower() {
                itemSettings.smartNaming = .off
                logger.info("On battery power: falling back to original filename for sweep item \(candidate.url.lastPathComponent)")
            }

            // Process canonical pipeline
            let itemNow = now
            let result = await processor.processItem(
                record: &record,
                settings: itemSettings,
                token: token,
                now: itemNow,
                onPhaseChange: { [weak self] newPhase in
                    status.phase = newPhase
                    self?.persistAndNotify(status: &status, onProgress: onProgress)
                }
            )

            // Update record in state
            workerState.records[recordIndex] = record

            switch result {
            case .uploaded:
                status.uploaded += 1
                status.completed += 1
                workerState.lastUploadAt = itemNow
                try? StateStore.save(workerState, paths)

            case .skipped:
                status.skipped += 1
                status.completed += 1
                try? StateStore.save(workerState, paths)

            case .rejected:
                status.skipped += 1
                status.completed += 1
                try? StateStore.save(workerState, paths)

            case .authRequired:
                status.state = .authRequired
                status.message = "Raindrop authentication required"
                try? StateStore.save(workerState, paths)
                persistAndNotify(status: &status, onProgress: onProgress)
                return status

            case .offline:
                status.state = .waitingForConnection
                status.message = "Waiting for network connection…"
                try? StateStore.save(workerState, paths)
                persistAndNotify(status: &status, onProgress: onProgress)
                return status

            case .rateLimited:
                status.message = "Rate limited by Raindrop"
                try? StateStore.save(workerState, paths)
                persistAndNotify(status: &status, onProgress: onProgress)
                return status

            case .powerRestricted:
                // If it returned powerRestricted despite fallback, don't mark completed
                try? StateStore.save(workerState, paths)

            case .retryableFailure(let error, _):
                status.failed += 1
                status.message = error.localizedDescription
                try? StateStore.save(workerState, paths)
            }

            status.remaining = max(0, status.total - status.completed)
            persistAndNotify(status: &status, onProgress: onProgress)
        }

        // 9. Finishing phase
        status.phase = .finishing
        persistAndNotify(status: &status, onProgress: onProgress)

        // Run due cleanup according to user's retention settings
        ScreenshotProcessor.processDueCleanup(
            state: &workerState,
            settings: settings,
            dryRun: false,
            now: now
        )
        try? StateStore.save(workerState, paths)

        // Notify namer batch finished
        await namer.finishBatch()

        // 10. Complete
        if status.state == .running {
            status.state = .completed
            status.phase = .complete
            status.message = "\(status.uploaded) of \(status.total) screenshots organized"
        }
        persistAndNotify(status: &status, onProgress: onProgress)

        logger.info("Sweep finished with state: \(status.state.rawValue), uploaded: \(status.uploaded), skipped: \(status.skipped), failed: \(status.failed)")
        return status
    }

    private func persistAndNotify(
        status: inout SweepStatus,
        onProgress: (@Sendable (SweepStatus) -> Void)?
    ) {
        status.updatedAt = Date()
        try? status.save(to: paths)
        onProgress?(status)

        // Broadcast to system and app
        NotificationCenter.default.post(
            name: NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: status
        )
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
