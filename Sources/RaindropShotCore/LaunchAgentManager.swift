import Foundation

public struct LegacyMigrationResult: Sendable {
    public let legacyPlistFound: Bool
    public let legacyPlistRemoved: Bool
    public let legacyUnloaded: Bool
    public let legacyEnvFound: Bool
    public let legacyCollectionId: Int?
    public let legacyTags: [String]?
    public let legacyScreenshotFolder: String?
}

public final class LaunchAgentManager: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths = .standard) {
        self.paths = paths
    }

    public var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public var workerPlistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(AppIdentity.workerIdentifier).plist")
    }

    public var legacyPlistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(AppIdentity.legacyAgentLabel).plist")
    }

    // MARK: - Legacy Migration

    /// Checks for and removes the legacy Node.js LaunchAgent and extracts any reusable non-secret config.
    public func migrateLegacyInstallation(legacyProjectDir: URL? = nil) -> LegacyMigrationResult {
        let legacyPlistExists = FileManager.default.fileExists(atPath: legacyPlistURL.path)
        var legacyUnloaded = false
        var legacyPlistRemoved = false

        if legacyPlistExists {
            // Unload legacy launchagent
            let uid = getuid()
            _ = runCommand("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(AppIdentity.legacyAgentLabel)"])
            _ = runCommand("/bin/launchctl", arguments: ["unload", legacyPlistURL.path])
            legacyUnloaded = true

            // Remove legacy plist
            do {
                try FileManager.default.removeItem(at: legacyPlistURL)
                legacyPlistRemoved = true
            } catch {
                legacyPlistRemoved = false
            }
        }

        // Check if old .env exists to read non-sensitive settings (collection, tags, folder)
        var envFound = false
        var colId: Int? = nil
        var tags: [String]? = nil
        var folder: String? = nil

        let candidateEnv = legacyProjectDir?.appendingPathComponent(".env")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")

        if let envContent = try? String(contentsOf: candidateEnv, encoding: .utf8) {
            envFound = true
            let lines = envContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || !trimmed.contains("=") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)

                if key == "RAINDROP_COLLECTION_ID", let parsed = Int(val) {
                    colId = parsed
                } else if key == "TAGS" {
                    tags = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else if key == "SCREENSHOT_FOLDER", !val.isEmpty {
                    folder = val
                }
            }
        }

        return LegacyMigrationResult(
            legacyPlistFound: legacyPlistExists,
            legacyPlistRemoved: legacyPlistRemoved,
            legacyUnloaded: legacyUnloaded,
            legacyEnvFound: envFound,
            legacyCollectionId: colId,
            legacyTags: tags,
            legacyScreenshotFolder: folder
        )
    }

    // MARK: - Native Worker LaunchAgent

    /// Installs the LaunchAgent plist for periodic background execution of `RaindropShotWorker`.
    public func installWorkerAgent(executablePath: String, cadenceSeconds: Int) throws {
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logPath = logsDir.appendingPathComponent("RaindropShotWorker.log").path
        let errPath = logsDir.appendingPathComponent("RaindropShotWorker.error.log").path

        let plistContent: [String: Any] = [
            "Label": AppIdentity.workerIdentifier,
            "ProgramArguments": [executablePath],
            "StartInterval": cadenceSeconds,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": errPath,
            "ProcessType": "Background",
            "LowPriorityIO": true
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try data.write(to: workerPlistURL, options: [.atomic])

        let uid = getuid()
        // Unload old registration if present
        _ = runCommand("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(AppIdentity.workerIdentifier)"])
        // Bootstrap new agent
        _ = runCommand("/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", workerPlistURL.path])
    }

    /// Unloads and removes the native LaunchAgent.
    public func uninstallWorkerAgent() {
        let uid = getuid()
        _ = runCommand("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(AppIdentity.workerIdentifier)"])
        try? FileManager.default.removeItem(at: workerPlistURL)
    }

    /// Checks if the worker LaunchAgent is currently loaded in launchd.
    public func isWorkerAgentLoaded() -> Bool {
        let uid = getuid()
        let result = runCommand("/bin/launchctl", arguments: ["print", "gui/\(uid)/\(AppIdentity.workerIdentifier)"])
        return result.exitCode == 0
    }

    /// Locates the compiled `RaindropShotWorker` executable reliably across dev and bundled modes.
    public static func locateWorkerExecutable() -> String {
        let bundleURL = Bundle.main.bundleURL

        // 1. Inside App bundle: Contents/MacOS/RaindropShotWorker
        let insideBundle = bundleURL.appendingPathComponent("Contents/MacOS/RaindropShotWorker")
        if FileManager.default.isExecutableFile(atPath: insideBundle.path) {
            return insideBundle.path
        }

        // 2. Sibling to app bundle (e.g. running inside repo root)
        let sibling = bundleURL.deletingLastPathComponent().appendingPathComponent("RaindropShotWorker")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }

        // 3. Inside .build/release
        let buildRelease = bundleURL.deletingLastPathComponent().appendingPathComponent(".build/release/RaindropShotWorker")
        if FileManager.default.isExecutableFile(atPath: buildRelease.path) {
            return buildRelease.path
        }

        // 4. Fallback to bundle location
        return insideBundle.path
    }

    /// Immediately triggers the worker asynchronously without blocking the UI thread.
    public func triggerImmediateRun(executablePath: String? = nil) {
        // Create request file
        try? paths.ensureDirectory()
        FileManager.default.createFile(atPath: paths.uploadNowRequest.path, contents: nil)

        let targetExec = executablePath ?? Self.locateWorkerExecutable()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let uid = getuid()
            let kickResult = self.runCommand(
                "/bin/launchctl",
                arguments: ["kickstart", "-k", "-p", "gui/\(uid)/\(AppIdentity.workerIdentifier)"],
                timeoutSeconds: 3.0
            )

            // If launchd agent not loaded or kickstart failed, spawn directly in background
            if kickResult.exitCode != 0 {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: targetExec)
                proc.arguments = ["--upload-now"]
                try? proc.run()
            }
        }
    }

    // MARK: - Process execution helper

    @discardableResult
    private func runCommand(
        _ command: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 4.0
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Watchdog timer to kill hanging commands (e.g. launchctl waiting indefinitely)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
