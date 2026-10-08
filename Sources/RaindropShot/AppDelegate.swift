import AppKit
import RaindropShotCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let paths = AppPaths.standard

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure default settings exist if first launch
        if Settings.load(from: paths) == nil {
            let defaultFolder = ScreenshotLocation.defaultFolder().path
            let initialSettings = Settings(screenshotFolder: defaultFolder)
            try? initialSettings.save(to: paths)
        }

        // Initialize menu bar item
        let controller = StatusItemController(paths: paths)
        self.statusItemController = controller

        // Initialize native notification center and connect action callbacks
        let notifCenter = AppNotificationCenter.shared
        notifCenter.setup()
        notifCenter.onOpenAuth = { [weak controller] in
            controller?.handleOpenAuth()
        }
        notifCenter.onOpenSettings = { [weak controller] in
            controller?.handleOpenSettings()
        }
        notifCenter.onCleanNow = { [weak controller] in
            controller?.handleCleanUpNow()
        }
        notifCenter.onOpenFolder = { [weak controller] in
            controller?.handleOpenFolder()
        }

        // Drain any pending worker notifications
        notifCenter.drainOutboxAndDeliver()

        // Check CLI flags or first-run state
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screens"), idx + 1 < args.count {
            let outPath = args[idx + 1]
            ScreenExporter.exportAllScreens(to: URL(fileURLWithPath: outPath), paths: paths)
            exit(0)
        }

        let settings = Settings.load(from: paths)
        let hasCompletedSetup = settings?.setupCompleted ?? false
        let hasToken = KeychainHelper().hasToken()

        if args.contains("--onboarding") || !hasCompletedSetup || !hasToken {
            controller.handleOpenOnboarding()
        } else if args.contains("--settings") {
            controller.handleOpenSettings()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        statusItemController = nil
    }
}
