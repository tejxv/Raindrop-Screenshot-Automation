import Foundation

/// Cheap, stable identity of a file: device + inode. Survives renames within a volume
/// and reboots on APFS. No hashing required.
public struct FileIdentity: Codable, Hashable, Sendable {
    public var device: Int64
    public var inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Lifecycle of one screenshot.
///
/// ```
/// pending ──▶ uploading ──▶ uploaded ──▶ cleaned
///    ▲  │         │  │            │
///    │  │         │  └─▶ unconfirmed (reconcile, then uploaded or pending)
///    │  │         └────▶ pending (failure + nextRetryAt) / rejected
///    │  └─▶ missing (file vanished before upload)
///    └──── (file modified before upload → stays pending with new size/mtime)
/// uploaded ──▶ kept (edited locally after upload — never deleted) / missing
/// ```
public enum ShotState: String, Codable, Sendable {
    /// Seen locally, not uploaded yet (may be waiting for delay, settle or retry).
    case pending
    /// An upload request is (or was) in flight. Persisted *before* the request starts.
    case uploading
    /// The request may or may not have reached Raindrop. Must reconcile before re-uploading.
    case unconfirmed
    /// Raindrop returned a definitive success. Local copy waits for retention.
    case uploaded
    /// Raindrop permanently refused the file (invalid / too large). Never deleted locally.
    case rejected
    /// Local file moved to Trash / deleted after retention.
    case cleaned
    /// Local file disappeared (moved or deleted by the user).
    case missing
    /// Local file changed after upload; kept forever so no unsynced edit is lost.
    case kept
    /// Byte-identical copy of an already tracked screenshot; not uploaded again.
    case duplicate

    /// States in which the record only exists to remember history.
    public var isTerminal: Bool {
        switch self {
        case .cleaned, .missing, .kept, .duplicate: true
        default: false
        }
    }

    public var isAwaitingUpload: Bool {
        self == .pending || self == .uploading || self == .unconfirmed
    }
}

public struct ShotRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var identity: FileIdentity
    public var size: Int64
    /// Exact mtime in nanoseconds (compared for equality, so no floating point).
    public var modifiedNanos: Int64
    /// File birth time — when the screenshot was captured.
    public var capturedAt: Date
    public var detectedAt: Date
    public var state: ShotState
    public var attempts: Int = 0
    public var lastAttemptAt: Date?
    public var nextRetryAt: Date?
    public var lastError: String?
    public var uploadedAt: Date?
    public var raindropId: Int?
    public var raindropLink: String?
    public var raindropCover: String?
    /// Tags / created date still need to be applied with a follow-up update.
    public var metadataPending: Bool = false
    public var metadataAttempts: Int = 0
    /// When the record reached a terminal state; used for pruning.
    public var finishedAt: Date?
    /// Only computed when needed to disambiguate copies.
    public var contentHash: String?
    /// A "failing repeatedly" notification was already sent for this record.
    public var failureNotified: Bool = false
    public var smartNamingAttempted: Bool = false
    public var generatedFilename: String?
    public var generatedTitle: String?
    public var generatedDescription: String?
    public var modelStatus: String?

    public init(id: UUID = UUID(), path: String, identity: FileIdentity, size: Int64,
                modifiedNanos: Int64, capturedAt: Date, detectedAt: Date, state: ShotState = .pending,
                smartNamingAttempted: Bool = false, generatedFilename: String? = nil,
                generatedTitle: String? = nil, generatedDescription: String? = nil, modelStatus: String? = nil) {
        self.id = id
        self.path = path
        self.identity = identity
        self.size = size
        self.modifiedNanos = modifiedNanos
        self.capturedAt = capturedAt
        self.detectedAt = detectedAt
        self.state = state
        self.smartNamingAttempted = smartNamingAttempted
        self.generatedFilename = generatedFilename
        self.generatedTitle = generatedTitle
        self.generatedDescription = generatedDescription
        self.modelStatus = modelStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, path, identity, size, modifiedNanos, capturedAt, detectedAt, state
        case attempts, lastAttemptAt, nextRetryAt, lastError, uploadedAt
        case raindropId, raindropLink, raindropCover, metadataPending, metadataAttempts
        case finishedAt, contentHash, failureNotified
        case smartNamingAttempted, generatedFilename, generatedTitle, generatedDescription, modelStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        identity = try c.decode(FileIdentity.self, forKey: .identity)
        size = try c.decode(Int64.self, forKey: .size)
        modifiedNanos = try c.decode(Int64.self, forKey: .modifiedNanos)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        detectedAt = try c.decode(Date.self, forKey: .detectedAt)
        state = try c.decode(ShotState.self, forKey: .state)
        attempts = (try? c.decodeIfPresent(Int.self, forKey: .attempts)) ?? 0
        lastAttemptAt = try? c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        nextRetryAt = try? c.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        uploadedAt = try? c.decodeIfPresent(Date.self, forKey: .uploadedAt)
        raindropId = try? c.decodeIfPresent(Int.self, forKey: .raindropId)
        raindropLink = try? c.decodeIfPresent(String.self, forKey: .raindropLink)
        raindropCover = try? c.decodeIfPresent(String.self, forKey: .raindropCover)
        metadataPending = (try? c.decodeIfPresent(Bool.self, forKey: .metadataPending)) ?? false
        metadataAttempts = (try? c.decodeIfPresent(Int.self, forKey: .metadataAttempts)) ?? 0
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        contentHash = try? c.decodeIfPresent(String.self, forKey: .contentHash)
        failureNotified = (try? c.decodeIfPresent(Bool.self, forKey: .failureNotified)) ?? false
        smartNamingAttempted = (try? c.decodeIfPresent(Bool.self, forKey: .smartNamingAttempted)) ?? false
        generatedFilename = try? c.decodeIfPresent(String.self, forKey: .generatedFilename)
        generatedTitle = try? c.decodeIfPresent(String.self, forKey: .generatedTitle)
        generatedDescription = try? c.decodeIfPresent(String.self, forKey: .generatedDescription)
        modelStatus = try? c.decodeIfPresent(String.self, forKey: .modelStatus)
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    /// Constructs the public, CDN-rendered cover URL that is accessible without authentication.
    public static func constructPublicCoverURL(id: Int, fileName: String) -> String {
        let idStr = String(id)
        var chunks: [String] = []
        var index = idStr.startIndex
        while index < idStr.endIndex {
            let nextIndex = idStr.index(index, offsetBy: 3, limitedBy: idStr.endIndex) ?? idStr.endIndex
            chunks.append(String(idStr[index..<nextIndex]))
            index = nextIndex
        }
        let chunkedPath = chunks.joined(separator: "/")

        // Raindrop sanitizes base filename by replacing non-alphanumerics with underscores
        let nsName = fileName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let sanitizedBase = base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let sanitizedFileName = ext.isEmpty ? sanitizedBase : "\(sanitizedBase).\(ext)"

        let innerURL = "https://up.raindrop.io/raindrop/files/\(chunkedPath)/\(sanitizedFileName)"
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedInner = innerURL.addingPercentEncoding(withAllowedCharacters: unreserved) ?? innerURL
        return "https://rdl.ink/render/\(encodedInner)"
    }

    /// True public shareable URL that can be opened by anyone without login.
    public var publicURL: String? {
        if let raindropCover, !raindropCover.isEmpty {
            return raindropCover
        }
        if let raindropId {
            return ShotRecord.constructPublicCoverURL(id: raindropId, fileName: fileName)
        }
        return raindropLink
    }

    mutating func finish(_ state: ShotState, at date: Date) {
        self.state = state
        self.finishedAt = date
        self.nextRetryAt = nil
    }
}

public struct AuthFailure: Codable, Equatable, Sendable {
    public var failedAt: Date
    /// `Settings.tokenGeneration` at the time of failure.
    public var generation: Int
    public var lastCheckedAt: Date
    public var notified: Bool = false
}

/// The durable manifest. Small, bounded, written atomically.
public struct WorkerState: Codable, Equatable, Sendable {
    public var version: Int = 1
    /// Files captured before this instant are never uploaded (no surprise bulk upload
    /// of an existing Desktop on first run).
    public var trackingSince: Date
    public var records: [ShotRecord] = []
    /// mtime of the screenshot folder at the last full scan (`nil` = scan next time).
    public var folderPath: String?
    public var folderStamp: Int64?
    public var auth: AuthFailure?
    public var rateLimitedUntil: Date?
    public var offlineSince: Date?
    public var lastRunAt: Date?
    public var lastUploadAt: Date?
    public var lastError: String?

    public init(trackingSince: Date) {
        self.trackingSince = trackingSince
    }
}

/// Tiny snapshot rendered by the menu bar. Written by the worker, read by the app.
public struct WorkerStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, running }
    public enum Health: String, Codable, Sendable {
        case ok, offline, authRequired, permissionDenied, folderMissing, needsSetup, error, paused
    }

    public var phase: Phase = .idle
    public var health: Health = .ok
    /// Not yet uploaded (including ones waiting for delay or retry).
    public var pending: Int = 0
    /// Subset of `pending` that has failed at least once, plus rejected files.
    public var failing: Int = 0
    /// Uploaded and still local, waiting for retention to elapse.
    public var awaitingCleanup: Int = 0
    public var lastRunAt: Date?
    public var lastUploadAt: Date?
    public var nextRetryAt: Date?
    public var message: String?
    public var updatedAt: Date

    public init(health: Health = .ok, updatedAt: Date = Date()) {
        self.health = health
        self.updatedAt = updatedAt
    }

    public static func load(from paths: AppPaths) -> WorkerStatus? {
        try? JSONStore.read(WorkerStatus.self, from: paths.status)
    }

    public func save(to paths: AppPaths) throws {
        try paths.ensureDirectory()
        try JSONStore.write(self, to: paths.status)
    }
}

/// Operational status record for a running or completed historical backlog sweep.
public struct SweepStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle
        case running
        case paused
        case stopped
        case waitingForPower
        case waitingForConnection
        case authRequired
        case completed
        case failed
    }

    public enum Phase: String, Codable, Sendable {
        case discovering
        case organizing
        case uploading
        case finishing
        case complete

        public var title: String {
            switch self {
            case .discovering: "Finding screenshots…"
            case .organizing: "Creating descriptive names…"
            case .uploading: "Uploading to Raindrop…"
            case .finishing: "Finishing up…"
            case .complete: "Screenshots organized"
            }
        }
    }

    public var jobId: String
    public var state: State
    public var phase: Phase
    public var total: Int
    public var completed: Int
    public var uploaded: Int
    public var skipped: Int
    public var failed: Int
    public var remaining: Int
    public var message: String?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        jobId: String = UUID().uuidString,
        state: State = .idle,
        phase: Phase = .discovering,
        total: Int = 0,
        completed: Int = 0,
        uploaded: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        remaining: Int = 0,
        message: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.jobId = jobId
        self.state = state
        self.phase = phase
        self.total = total
        self.completed = completed
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
        self.remaining = remaining
        self.message = message
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public static func load(from paths: AppPaths) -> SweepStatus? {
        try? JSONStore.read(SweepStatus.self, from: paths.sweepStatus)
    }

    public func save(to paths: AppPaths) throws {
        try paths.ensureDirectory()
        try JSONStore.write(self, to: paths.sweepStatus)
    }

    /// Accessibility description for VoiceOver.
    public var accessibilityValue: String {
        let percent = total > 0 ? Int((Double(completed) / Double(total)) * 100) : 0
        return "\(completed) of \(total) screenshots processed, \(percent) percent"
    }
}

// MARK: - Persistence

public enum StateStore {
    public enum LoadResult {
        case loaded(WorkerState)
        case fresh(WorkerState)
        /// The manifest was unreadable. It was moved aside and a new baseline starts now,
        /// which guarantees no previously-uploaded file is uploaded again.
        case recoveredFromCorruption(WorkerState)

        public var state: WorkerState {
            switch self {
            case .loaded(let s), .fresh(let s), .recoveredFromCorruption(let s): s
            }
        }
    }

    public static func load(_ paths: AppPaths, now: Date) -> LoadResult {
        let url = paths.state
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fresh(WorkerState(trackingSince: now))
        }
        do {
            return .loaded(try JSONStore.read(WorkerState.self, from: url))
        } catch {
            let stamp = Int(now.timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("state.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return .recoveredFromCorruption(WorkerState(trackingSince: now))
        }
    }

    public static func save(_ state: WorkerState, _ paths: AppPaths) throws {
        try paths.ensureDirectory()
        try JSONStore.write(state, to: paths.state)
    }
}
