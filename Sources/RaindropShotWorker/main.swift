import Foundation
import RaindropShotCore

@main
struct WorkerMain {
    static func main() async {
        let args = ProcessInfo.processInfo.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        if args.contains("--version") || args.contains("-v") {
            print("RaindropShotWorker version 1.0.0 (Native Swift)")
            exit(0)
        }

        let paths = AppPaths.standard

        if args.contains("--install-agent") {
            let manager = LaunchAgentManager(paths: paths)
            let settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
            let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let resolvedPath = URL(fileURLWithPath: execPath).standardized.path
            do {
                try manager.installWorkerAgent(executablePath: resolvedPath, cadenceSeconds: settings.cadence.rawValue)
                print("✓ LaunchAgent installed to \(manager.workerPlistURL.path)")
                print("✓ Loaded into launchd (Cadence: \(settings.cadence.title), KeepAlive: false)")
            } catch {
                print("❌ Failed to install LaunchAgent: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }

        if args.contains("--uninstall-agent") {
            let manager = LaunchAgentManager(paths: paths)
            manager.uninstallWorkerAgent()
            print("✓ LaunchAgent uninstalled and removed from launchd.")
            exit(0)
        }

        // Handler: --set-token <token>
        if let idx = args.firstIndex(of: "--set-token"), idx + 1 < args.count {
            let token = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let keychain = KeychainHelper()
            do {
                try keychain.saveToken(token)
                print("✓ Token saved securely to macOS Keychain.")

                // Test connection
                let api = RaindropAPI()
                let ok = try await api.testConnection(token: token)
                if ok {
                    let quota = try? await api.getUserQuota(token: token)
                    if let q = quota {
                        print(String(format: "✓ API connection successful! Storage: %.1fMB / %.1fMB used (%d%%)", q.usedMB, q.totalMB, q.usedPercent))
                    } else {
                        print("✓ API connection successful!")
                    }

                    // Update settings setupCompleted flag if settings exist
                    var settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
                    settings.setupCompleted = true
                    settings.tokenGeneration += 1
                    try? settings.save(to: paths)
                } else {
                    print("⚠️ Could not verify token with Raindrop.io API.")
                }
            } catch {
                print("❌ Failed: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }

        // Handler: --auth-url [--client-id <id>] [--redirect-uri <uri>]
        if args.contains("--auth-url") {
            let clientId = valueForFlag("--client-id", in: args) ?? "68789ff689798d7d715b1143"
            let redirectUri = valueForFlag("--redirect-uri", in: args) ?? OAuthHelper.defaultRedirectURI
            if let url = OAuthHelper().buildAuthorizeURL(clientId: clientId, redirectUri: redirectUri) {
                print("Authorize URL:")
                print(url.absoluteString)
            }
            exit(0)
        }

        // Handler: --exchange-code <code> [--client-id <id>] [--client-secret <secret>] [--redirect-uri <uri>]
        if let idx = args.firstIndex(of: "--exchange-code"), idx + 1 < args.count {
            let code = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let clientId = valueForFlag("--client-id", in: args) ?? "68789ff689798d7d715b1143"
            let clientSecret = valueForFlag("--client-secret", in: args) ?? "643231c3-c93e-40dd-a808-fcf2d680cdaf"
            let redirectUri = valueForFlag("--redirect-uri", in: args) ?? OAuthHelper.defaultRedirectURI

            print("Exchanging authorization code with Raindrop.io...")
            do {
                let oauth = OAuthHelper()
                let resp = try await oauth.exchangeCode(
                    code: code,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    redirectUri: redirectUri
                )
                let token = resp.access_token
                print("✓ Successfully obtained access token!")

                let keychain = KeychainHelper()
                try keychain.saveToken(token)
                print("✓ Token saved securely to macOS Keychain.")

                let api = RaindropAPI()
                let ok = try await api.testConnection(token: token)
                if ok {
                    let quota = try? await api.getUserQuota(token: token)
                    if let q = quota {
                        print(String(format: "✓ API connection successful! Storage: %.1fMB / %.1fMB used (%d%%)", q.usedMB, q.totalMB, q.usedPercent))
                    } else {
                        print("✓ API connection successful!")
                    }

                    var settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
                    settings.setupCompleted = true
                    settings.tokenGeneration += 1
                    try? settings.save(to: paths)
                }
            } catch {
                print("❌ OAuth exchange failed: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }

        if args.contains("--status") {
            if let status = WorkerStatus.load(from: paths) {
                print("Status: \(status.health)")
                print("Message: \(status.message ?? "None")")
                print("Pending: \(status.pending)")
                print("Awaiting cleanup: \(status.awaitingCleanup)")
                print("Failing: \(status.failing)")
                if let lastRun = status.lastRunAt {
                    print("Last run: \(lastRun)")
                }
                if let lastUpload = status.lastUploadAt {
                    print("Last upload: \(lastUpload)")
                }
            } else {
                print("No status recorded yet.")
            }
            exit(0)
        }

        if args.contains("--clean-now") {
            let engine = WorkerEngine(paths: paths)
            let count = await engine.cleanUploadedNow()
            print("✓ Cleaned up \(count) uploaded screenshot(s).")
            exit(0)
        }

        if args.contains("--sweep") {
            let coordinator = SweepCoordinator(paths: paths)
            print("Starting sweep of existing screenshots...")
            let status = await coordinator.runSweep { update in
                if args.contains("--verbose") {
                    print("[\(update.phase.rawValue)] \(update.completed)/\(update.total) (uploaded: \(update.uploaded), skipped: \(update.skipped), failed: \(update.failed))")
                }
            }
            print("Sweep finished. State: \(status.state.rawValue), \(status.uploaded) of \(status.total) screenshots organized.")
            exit(status.state == .completed ? 0 : 1)
        }

        if args.contains("--stop-sweep") {
            SweepCoordinator.requestStop(paths: paths)
            print("Requested sweep stop.")
            exit(0)
        }

        let isDryRun = args.contains("--dry-run")
        let isUploadNow = args.contains("--upload-now")
        let isVerbose = args.contains("--verbose")

        let options = WorkerEngineOptions(
            dryRun: isDryRun,
            forceUploadNow: isUploadNow,
            verbose: isVerbose
        )

        let engine = WorkerEngine(paths: paths)
        let status = await engine.run(options: options)

        if isVerbose || isDryRun {
            print("Finished run. Health: \(status.health), Message: \(status.message ?? "None"), Pending: \(status.pending)")
        }

        // Return non-zero exit code if fatal configuration error
        switch status.health {
        case .authRequired, .folderMissing, .needsSetup:
            exit(1)
        default:
            exit(0)
        }
    }

    static func valueForFlag(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func printUsage() {
        print("""
        RaindropShotWorker - Native macOS background screenshot uploader

        Usage:
          RaindropShotWorker [options]

        Options:
          --dry-run                         Inspect files and report what would be uploaded and cleaned up
          --upload-now                      Upload eligible screenshots immediately, ignoring upload delay
          --sweep                           Run historical backlog sweep on existing screenshots
          --stop-sweep                      Request a running sweep to stop
          --status                          Print current worker status snapshot from disk and exit
          --set-token <token>               Save API token directly into macOS Keychain and verify connection
          --auth-url                        Print the OAuth authorization URL
          --exchange-code <code>            Exchange OAuth code for token and save to Keychain
          --client-id <id>                  OAuth client ID (optional if using defaults)
          --client-secret <secret>          OAuth client secret (optional if using defaults)
          --redirect-uri <uri>              OAuth redirect URI (default: http://localhost:7890/callback)
          --verbose                         Print extra diagnostic details to standard output
          --version                         Print version information
          --help                            Show this help message

        This utility performs one unit of work and exits immediately.
        It is invoked periodically by launchd (via ~/Library/LaunchAgents).
        """)
    }
}
