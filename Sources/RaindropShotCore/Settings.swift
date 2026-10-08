import Foundation

// MARK: - Options

/// How long after capture a screenshot becomes eligible for upload.
public enum UploadDelay: Int, Codable, CaseIterable, Sendable {
    case asap = 0
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case manual = -1

    /// `nil` means "never automatically".
    public var interval: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .asap: "As soon as possible"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        case .thirtyMinutes: "After 30 minutes"
        case .oneHour: "After 1 hour"
        case .manual: "Manually"
        }
    }
}

/// How long a screenshot stays local after a *confirmed* upload.
public enum Retention: Int, Codable, CaseIterable, Sendable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case oneDay = 86_400
    case sevenDays = 604_800
    case never = -1

    public var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .oneDay: "24 hours"
        case .sevenDays: "7 days"
        case .never: "Forever"
        }
    }
}

public enum CleanupAction: String, Codable, CaseIterable, Sendable {
    case trash
    case delete
    case keep

    public var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete permanently"
        case .keep: "Keep"
        }
    }
}

/// How often launchd starts the worker. Each case maps to one bundled LaunchAgent plist.
public enum Cadence: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600

    public var label: String { "\(AppIdentity.workerIdentifier).\(rawValue)" }
    public var plistName: String { "\(label).plist" }

    public var title: String {
        switch self {
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .oneHour: "Every hour"
        }
    }
}

public enum DetectionMode: String, Codable, CaseIterable, Sendable {
    /// macOS screenshot metadata or screenshot-like file names only.
    case screenshotsOnly
    /// Every supported image in the folder (for a dedicated screenshots folder / third-party tools).
    case allImages

    public var title: String {
        switch self {
        case .screenshotsOnly: "Screenshots only"
        case .allImages: "All images in folder"
        }
    }
}

public enum SmartNamingMode: String, Codable, CaseIterable, Sendable {
    case off
    case onDevice

    public var title: String {
        switch self {
        case .off: "Off"
        case .onDevice: "On-Device (Apple Intelligence)"
        }
    }
}

public enum SmartNamingApplyTo: String, Codable, CaseIterable, Sendable {
    case both
    case raindropOnly
    case localOnly

    public var title: String {
        switch self {
        case .both: "Local file + Raindrop"
        case .raindropOnly: "Raindrop only"
        case .localOnly: "Local file only"
        }
    }

    public var appliesToLocalFile: Bool {
        self == .both || self == .localOnly
    }

    public var appliesToRaindrop: Bool {
        self == .both || self == .raindropOnly
    }
}

// MARK: - Settings

/// User configuration shared by app (writer) and worker (reader). Contains no secrets.
public struct Settings: Codable, Equatable, Sendable {
    public var screenshotFolder: String
    public var detection: DetectionMode = .screenshotsOnly
    public var uploadDelay: UploadDelay = .asap
    public var retention: Retention = .fiveMinutes
    public var cleanupAction: CleanupAction = .trash
    public var cadence: Cadence = .fiveMinutes
    public var paused: Bool = false
    public var smartNaming: SmartNamingMode = .onDevice
    public var smartNamingApplyTo: SmartNamingApplyTo = .both
    public var smartNamingOnlyOnPower: Bool = false
    /// `nil` → Raindrop's "Unsorted".
    public var collectionId: Int?
    public var collectionTitle: String?
    public var tags: [String] = ["screenshot", "macos"]
    public var notifyOnSuccess: Bool = false
    public var copyScreenshotToClipboard: Bool = false
    public var copyLinkToClipboardOnUpload: Bool = false
    /// Bumped by the app whenever the token changes, so the worker can leave the
    /// auth-required back-off immediately without ever seeing the token itself.
    public var tokenGeneration: Int = 0
    public var setupCompleted: Bool = false

    public init(screenshotFolder: String) {
        self.screenshotFolder = screenshotFolder
    }

    public var folderURL: URL { URL(fileURLWithPath: (screenshotFolder as NSString).expandingTildeInPath, isDirectory: true) }

    /// Effective time a confirmed upload stays local, or `nil` if it is never cleaned up.
    public var effectiveRetention: TimeInterval? {
        cleanupAction == .keep ? nil : retention.interval
    }

    // Tolerant decoding: unknown/missing keys fall back to defaults, so old and new
    // builds can share the file without a migration step.
    enum CodingKeys: String, CodingKey {
        case screenshotFolder, detection, uploadDelay, retention, cleanupAction, cadence, paused
        case smartNaming, smartNamingApplyTo, smartNamingOnlyOnPower
        case collectionId, collectionTitle, tags, notifyOnSuccess, tokenGeneration, setupCompleted
        case copyScreenshotToClipboard, copyLinkToClipboardOnUpload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(screenshotFolder: try c.decodeIfPresent(String.self, forKey: .screenshotFolder) ?? ScreenshotLocation.defaultFolder().path)
        detection = (try? c.decodeIfPresent(DetectionMode.self, forKey: .detection)) ?? detection
        uploadDelay = (try? c.decodeIfPresent(UploadDelay.self, forKey: .uploadDelay)) ?? uploadDelay
        retention = (try? c.decodeIfPresent(Retention.self, forKey: .retention)) ?? retention
        cleanupAction = (try? c.decodeIfPresent(CleanupAction.self, forKey: .cleanupAction)) ?? cleanupAction
        cadence = (try? c.decodeIfPresent(Cadence.self, forKey: .cadence)) ?? cadence
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? paused
        smartNaming = (try? c.decodeIfPresent(SmartNamingMode.self, forKey: .smartNaming)) ?? smartNaming
        smartNamingApplyTo = (try? c.decodeIfPresent(SmartNamingApplyTo.self, forKey: .smartNamingApplyTo)) ?? smartNamingApplyTo
        smartNamingOnlyOnPower = (try? c.decodeIfPresent(Bool.self, forKey: .smartNamingOnlyOnPower)) ?? smartNamingOnlyOnPower
        collectionId = try? c.decodeIfPresent(Int.self, forKey: .collectionId)
        collectionTitle = try? c.decodeIfPresent(String.self, forKey: .collectionTitle)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? tags
        notifyOnSuccess = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess)) ?? notifyOnSuccess
        copyScreenshotToClipboard = (try? c.decodeIfPresent(Bool.self, forKey: .copyScreenshotToClipboard)) ?? copyScreenshotToClipboard
        copyLinkToClipboardOnUpload = (try? c.decodeIfPresent(Bool.self, forKey: .copyLinkToClipboardOnUpload)) ?? copyLinkToClipboardOnUpload
        tokenGeneration = (try? c.decodeIfPresent(Int.self, forKey: .tokenGeneration)) ?? tokenGeneration
        setupCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .setupCompleted)) ?? setupCompleted
    }

    public static func load(from paths: AppPaths) -> Settings? {
        guard let data = try? Data(contentsOf: paths.settings) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    public func save(to paths: AppPaths) throws {
        try paths.ensureDirectory()
        try JSONStore.write(self, to: paths.settings)
    }

    /// Normalises a comma-separated tag string.
    public static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Atomic JSON helper

public enum JSONStore {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(value)
        // `.atomic` writes to a temp file and renames, so readers never see a torn file
        // and a crash mid-write leaves the previous version intact.
        try data.write(to: url, options: [.atomic])
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
