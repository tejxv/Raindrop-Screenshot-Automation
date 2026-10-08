import Foundation

/// Identifiers shared by the app, the worker and the launchd plists.
public enum AppIdentity {
    public static let appName = "RaindropShot"
    public static let bundleIdentifier = "com.tejxv.RaindropShot"
    public static let workerIdentifier = "com.tejxv.RaindropShot.worker"
    public static let logSubsystem = "com.tejxv.RaindropShot"
    /// Darwin notification posted by the worker whenever it rewrites `status.json`.
    public static let statusNotification = "com.tejxv.RaindropShot.status-changed"
    /// Darwin notification posted whenever sweep status changes.
    public static let sweepStatusNotification = "com.tejxv.RaindropShot.sweep-status-changed"
    /// Keychain service name for the Raindrop token.
    public static let keychainService = "com.tejxv.RaindropShot.token"
    public static let keychainAccount = "raindrop"

    /// Label of the old Node.js LaunchAgent this project replaces.
    public static let legacyAgentLabel = "com.raindrop.screenshot.automation"
}

/// Every file the system persists. All of it lives in one private directory.
public struct AppPaths: Sendable {
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// `~/Library/Application Support/RaindropShot/`
    public static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(supportDirectory: base.appendingPathComponent(AppIdentity.appName, isDirectory: true))
    }

    public var settings: URL { supportDirectory.appendingPathComponent("settings.json") }
    public var state: URL { supportDirectory.appendingPathComponent("state.json") }
    public var status: URL { supportDirectory.appendingPathComponent("status.json") }
    public var sweepStatus: URL { supportDirectory.appendingPathComponent("sweep.json") }
    /// Held (flock) by a running worker. Prevents concurrent workers.
    public var workerLock: URL { supportDirectory.appendingPathComponent("worker.lock") }
    /// Held (flock) by a running sweep. Prevents concurrent sweeps.
    public var sweepLock: URL { supportDirectory.appendingPathComponent("sweep.lock") }
    /// Held (flock) by the menu bar app while it runs, so the worker knows it is there.
    public var menuBarLock: URL { supportDirectory.appendingPathComponent("menubar.lock") }
    /// Presence = "Upload now" was requested. Consumed by the next worker.
    public var uploadNowRequest: URL { supportDirectory.appendingPathComponent("upload-now.request") }
    /// Presence = Sweep stop requested.
    public var sweepStopRequest: URL { supportDirectory.appendingPathComponent("sweep-stop.request") }
    /// Pending user notifications written by the worker, delivered by the app.
    public var outbox: URL { supportDirectory.appendingPathComponent("outbox.json") }

    /// Creates the support directory as owner-only (0700). Tokens never live here,
    /// but screenshot paths are still private information.
    public func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: supportDirectory.path) {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }
}
