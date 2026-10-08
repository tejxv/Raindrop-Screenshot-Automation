import AppKit
import RaindropShotCore
import Darwin

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let paths: AppPaths
    private var notifyToken: Int32 = 0
    private var settingsWindowController: SettingsWindowController?
    private var quickAuthWindowController: QuickAuthWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var aboutWindowController: AboutWindowController?

    public init(paths: AppPaths = .standard) {
        self.paths = paths
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        statusItem.menu = menu

        updateStatusIcon()
        setupDarwinNotificationListener()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(AppIdentity.statusNotification as CFString),
            nil
        )
    }

    // MARK: - Darwin Notification

    private func setupDarwinNotificationListener() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let controller = Unmanaged<StatusItemController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.updateStatusIcon()
                    AppNotificationCenter.shared.drainOutboxAndDeliver()
                }
            },
            AppIdentity.statusNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Icon State

    public func updateStatusIcon() {
        let status = WorkerStatus.load(from: paths)
        let settings = Settings.load(from: paths)

        let isPaused = settings?.paused ?? false
        let health = status?.health ?? .ok
        let pending = status?.pending ?? 0

        let sweepStatus = SweepStatus.load(from: paths)
        let isSweepRunning = sweepStatus?.state == .running

        let symbolName: String
        let accessibilityDesc: String

        if isSweepRunning, let sw = sweepStatus {
            symbolName = "sparkles.rectangle.stack"
            accessibilityDesc = "RaindropShot: Organizing screenshots (\(sw.completed) of \(sw.total))"
        } else if isPaused {
            symbolName = "pause.circle"
            accessibilityDesc = "RaindropShot: Paused"
        } else {
            switch health {
            case .authRequired, .error, .permissionDenied:
                symbolName = "exclamationmark.triangle"
                accessibilityDesc = "RaindropShot: Attention Required"
            case .offline:
                symbolName = "wifi.slash"
                accessibilityDesc = "RaindropShot: Offline"
            case .folderMissing:
                symbolName = "folder.badge.questionmark"
                accessibilityDesc = "RaindropShot: Folder Missing"
            case .needsSetup:
                symbolName = "gearshape.badge.exclamationmark"
                accessibilityDesc = "RaindropShot: Setup Needed"
            case .ok:
                if pending > 0 {
                    symbolName = "arrow.up.circle"
                    accessibilityDesc = "RaindropShot: \(pending) Pending"
                } else {
                    symbolName = "checkmark.circle"
                    accessibilityDesc = "RaindropShot: Synced"
                }
            case .paused:
                symbolName = "pause.circle"
                accessibilityDesc = "RaindropShot: Paused"
            }
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDesc)
            image?.isTemplate = true
            button.image = image
        }
    }

    // MARK: - NSMenuDelegate (Dynamic Build on Open)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = WorkerStatus.load(from: paths)
        let settings = Settings.load(from: paths)
        let isPaused = settings?.paused ?? false
        let requiresAuth = (status?.health == .authRequired || status?.health == .needsSetup)

        // 1. Refined Status Header Card
        let headerConfig: StatusHeaderView.Config
        if requiresAuth {
            headerConfig = StatusHeaderView.Config(
                title: "Raindrop.io",
                subtitle: "Sign-in required",
                dotColor: .systemRed,
                buttonTitle: "Sign In",
                buttonColor: .controlAccentColor,
                buttonAction: { [weak self] in self?.handleOpenAuth() }
            )
        } else if isPaused {
            headerConfig = StatusHeaderView.Config(
                title: "Sync Paused",
                subtitle: "Automatic uploads paused",
                dotColor: .systemOrange,
                buttonTitle: "Resume",
                buttonColor: .systemOrange,
                buttonAction: { [weak self] in self?.handleTogglePause() }
            )
        } else if let st = status {
            switch st.health {
            case .offline:
                headerConfig = StatusHeaderView.Config(
                    title: "Offline",
                    subtitle: "Will upload when connected",
                    dotColor: .systemGray,
                    buttonTitle: "Retry",
                    buttonColor: .secondaryLabelColor,
                    buttonAction: { [weak self] in self?.handleUploadNow() }
                )
            case .folderMissing:
                headerConfig = StatusHeaderView.Config(
                    title: "Folder Missing",
                    subtitle: "Check folder in Settings",
                    dotColor: .systemRed,
                    buttonTitle: "Settings",
                    buttonColor: .systemRed,
                    buttonAction: { [weak self] in self?.handleOpenSettings() }
                )
            case .permissionDenied:
                headerConfig = StatusHeaderView.Config(
                    title: "Permission Denied",
                    subtitle: "Folder permission needed",
                    dotColor: .systemRed,
                    buttonTitle: "Fix",
                    buttonColor: .systemRed,
                    buttonAction: { [weak self] in self?.handleOpenFolder() }
                )
            case .error:
                headerConfig = StatusHeaderView.Config(
                    title: "Sync Error",
                    subtitle: st.message ?? "An error occurred",
                    dotColor: .systemRed,
                    buttonTitle: "Retry",
                    buttonColor: .systemRed,
                    buttonAction: { [weak self] in self?.handleUploadNow() }
                )
            case .ok:
                if st.pending > 0 {
                    headerConfig = StatusHeaderView.Config(
                        title: "\(st.pending) Pending",
                        subtitle: "Syncing in background…",
                        dotColor: .systemBlue,
                        buttonTitle: "Upload Now",
                        buttonColor: .controlAccentColor,
                        buttonAction: { [weak self] in self?.handleUploadNow() }
                    )
                } else {
                    let relative = (st.lastUploadAt ?? st.lastRunAt).map { timeAgoString(from: $0) } ?? "just now"
                    headerConfig = StatusHeaderView.Config(
                        title: "Synced",
                        subtitle: "Updated \(relative)",
                        dotColor: .systemGreen,
                        buttonTitle: "Sync Now",
                        buttonColor: .controlAccentColor,
                        buttonAction: { [weak self] in self?.handleUploadNow() }
                    )
                }
            case .authRequired, .needsSetup, .paused:
                headerConfig = StatusHeaderView.Config(
                    title: "Ready",
                    subtitle: "Background sync active",
                    dotColor: .systemGreen,
                    buttonTitle: "Sync Now",
                    buttonAction: { [weak self] in self?.handleUploadNow() }
                )
            }
        } else {
            headerConfig = StatusHeaderView.Config(
                title: "Ready",
                subtitle: "Zero idle resource usage",
                dotColor: .systemGreen,
                buttonTitle: "Sync Now",
                buttonAction: { [weak self] in self?.handleUploadNow() }
            )
        }

        let headerItem = NSMenuItem()
        headerItem.view = StatusHeaderView(config: headerConfig)
        menu.addItem(headerItem)

        // If Authentication Required: minimal auth flow
        if requiresAuth {
            let authItem = NSMenuItem(title: "Sign In to Raindrop", action: #selector(handleOpenAuth), keyEquivalent: "")
            authItem.target = self
            let authButtonView = AuthButtonView(
                title: "Sign In to Raindrop (1-Click)",
                iconName: "safari",
                width: 240,
                height: 38
            ) { [weak self] in
                self?.handleOpenAuth()
            }
            authItem.view = authButtonView
            menu.addItem(authItem)

            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.count >= 20 && clip.count <= 64 && !clip.contains(" ") && !clip.contains("\n") {
                let clipItem = NSMenuItem(title: "Connect with Copied Token (\(clip.prefix(8))…)", action: #selector(handleConnectWithClipboardToken), keyEquivalent: "")
                clipItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
                clipItem.target = self
                menu.addItem(clipItem)
            }

            menu.addItem(NSMenuItem.separator())
            let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
            settingsItem.target = self
            settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            menu.addItem(settingsItem)

            let quitItem = NSMenuItem(title: "Quit RaindropShot", action: #selector(handleQuit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            return
        }

        menu.addItem(NSMenuItem.separator())

        // 2. Active Sweep Progress (Conditional ONLY when sweep is active)
        let sweepStatus = SweepStatus.load(from: paths)
        let isSweepActive = sweepStatus?.state == .running || sweepStatus?.state == .paused

        if let sw = sweepStatus, isSweepActive {
            let sweepHeaderTitle = (sw.state == .paused) ? "Sweep Paused (\(sw.completed) of \(sw.total))" : "Organizing Backlog (\(sw.completed) of \(sw.total))"
            let sweepItem = NSMenuItem(title: sweepHeaderTitle, action: #selector(handleShowSweepProgress), keyEquivalent: "")
            sweepItem.target = self
            sweepItem.image = NSImage(systemSymbolName: sw.state == .paused ? "pause.circle.fill" : "sparkles.rectangle.stack.fill", accessibilityDescription: nil)

            let sweepSubmenu = NSMenu()
            let progressItem = NSMenuItem(title: "Show Sweep Progress…", action: #selector(handleShowSweepProgress), keyEquivalent: "")
            progressItem.target = self
            sweepSubmenu.addItem(progressItem)

            let pauseSweepTitle = (sw.state == .paused) ? "Resume Sweep" : "Pause Sweep"
            let pauseSweepItem = NSMenuItem(title: pauseSweepTitle, action: #selector(handleToggleSweepPause), keyEquivalent: "")
            pauseSweepItem.target = self
            sweepSubmenu.addItem(pauseSweepItem)

            let stopSweepItem = NSMenuItem(title: "Stop Sweep", action: #selector(handleStopSweepFromMenu), keyEquivalent: "")
            stopSweepItem.target = self
            sweepSubmenu.addItem(stopSweepItem)

            sweepItem.submenu = sweepSubmenu
            menu.addItem(sweepItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 3. Core Actions: Recent Uploads, Clean Up, Open Folder
        let stateResult = StateStore.load(paths, now: Date())
        let uploadedRecords = stateResult.state.records
            .filter { $0.uploadedAt != nil }
            .sorted { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }

        let recentItem = NSMenuItem(title: "Recent Uploads", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let recentMenu = NSMenu()

        if uploadedRecords.isEmpty {
            let emptyItem = NSMenuItem(title: "No uploads yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for record in uploadedRecords.prefix(5) {
                let dateStr = record.uploadedAt.map { timeAgoString(from: $0) } ?? ""
                let title = "\(record.fileName) (\(dateStr))"
                let shotItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                shotItem.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)

                let itemSubmenu = NSMenu()

                if let publicLink = record.publicURL, let publicURL = URL(string: publicLink) {
                    let copyPublic = NSMenuItem(title: "Copy Public Link", action: #selector(handleCopyPublicLink(_:)), keyEquivalent: "")
                    copyPublic.target = self
                    copyPublic.representedObject = publicURL
                    copyPublic.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy Public Link")
                    itemSubmenu.addItem(copyPublic)
                }

                let fileURL = URL(fileURLWithPath: record.path)
                let localExists = FileManager.default.fileExists(atPath: record.path)
                if localExists {
                    let copyImageItem = NSMenuItem(title: "Copy Image to Clipboard", action: #selector(handleCopyImage(_:)), keyEquivalent: "")
                    copyImageItem.target = self
                    copyImageItem.representedObject = fileURL
                    copyImageItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Copy Image")
                    itemSubmenu.addItem(copyImageItem)
                }

                if let id = record.raindropId, let raindropWebURL = URL(string: "https://app.raindrop.io/my/0/item/\(id)") {
                    let openRaindrop = NSMenuItem(title: "View on Raindrop.io", action: #selector(handleOpenURL(_:)), keyEquivalent: "")
                    openRaindrop.target = self
                    openRaindrop.representedObject = raindropWebURL
                    openRaindrop.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
                    itemSubmenu.addItem(openRaindrop)
                }

                itemSubmenu.addItem(NSMenuItem.separator())

                if localExists {
                    let showInFinder = NSMenuItem(title: "Show in Finder", action: #selector(handleRevealFile(_:)), keyEquivalent: "")
                    showInFinder.target = self
                    showInFinder.representedObject = fileURL
                    showInFinder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    itemSubmenu.addItem(showInFinder)
                } else {
                    let cleanedItem = NSMenuItem(title: "Local copy cleaned up", action: nil, keyEquivalent: "")
                    cleanedItem.isEnabled = false
                    itemSubmenu.addItem(cleanedItem)
                }

                shotItem.submenu = itemSubmenu
                recentMenu.addItem(shotItem)
            }
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        // Clean Up Local Screenshots
        let awaitingCleanup = status?.awaitingCleanup ?? 0
        let cleanTitle = awaitingCleanup > 0 ? "Clean Up Local Screenshots (\(awaitingCleanup))" : "Clean Up Local Screenshots"
        let cleanItem = NSMenuItem(title: cleanTitle, action: #selector(handleCleanUpNow), keyEquivalent: "")
        cleanItem.target = self
        cleanItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(cleanItem)

        // Open Screenshots Folder (with Option alternate for Organize Existing Screenshots)
        let openFolderItem = NSMenuItem(title: "Open Screenshots Folder", action: #selector(handleOpenFolder), keyEquivalent: "")
        openFolderItem.target = self
        openFolderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(openFolderItem)

        let sweepAlternate = NSMenuItem(title: "Organize Existing Screenshots…", action: #selector(handleStartSweepFromMenu), keyEquivalent: "")
        sweepAlternate.isAlternate = true
        sweepAlternate.keyEquivalentModifierMask = [.option]
        sweepAlternate.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
        sweepAlternate.target = self
        menu.addItem(sweepAlternate)

        menu.addItem(NSMenuItem.separator())

        // 4. Pause / Resume Automatic Sync
        let pauseTitle = isPaused ? "Resume Automatic Sync" : "Pause Automatic Sync"
        let pauseIcon = isPaused ? "play" : "pause"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(handleTogglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.image = NSImage(systemSymbolName: pauseIcon, accessibilityDescription: nil)
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Settings & Quit (with Option alternate for About)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutAlternate = NSMenuItem(title: "About RaindropShot…", action: #selector(handleOpenAbout), keyEquivalent: "")
        aboutAlternate.isAlternate = true
        aboutAlternate.keyEquivalentModifierMask = [.option]
        aboutAlternate.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        aboutAlternate.target = self
        menu.addItem(aboutAlternate)

        let quitItem = NSMenuItem(title: "Quit RaindropShot", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleStopSweepFromMenu() {
        SweepCoordinator.requestStop(paths: paths)
    }

    // MARK: - Actions

    @objc public func handleUploadNow() {
        LaunchAgentManager(paths: paths).triggerImmediateRun()
        // Provide immediate visual feedback
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Uploading")
        }
    }

    @objc public func handleCleanUpNow() {
        Task {
            let engine = WorkerEngine(paths: self.paths)
            _ = await engine.cleanUploadedNow()
            await MainActor.run {
                self.updateStatusIcon()
            }
        }
    }

    @objc public func handleTogglePause() {
        guard var settings = Settings.load(from: paths) else { return }
        settings.paused.toggle()
        try? settings.save(to: paths)
        updateStatusIcon()
    }

    @objc public func handleOpenFolder() {
        let folderURL = Settings.load(from: paths)?.folderURL ?? ScreenshotLocation.defaultFolder()
        NSWorkspace.shared.open(folderURL)
    }

    @objc public func handleOpenSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(paths: paths, onDismiss: { [weak self] in
                self?.settingsWindowController = nil
                self?.updateStatusIcon()
            })
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func handleOpenAuth() {
        if quickAuthWindowController == nil {
            quickAuthWindowController = QuickAuthWindowController(paths: paths, onDismiss: { [weak self] in
                self?.quickAuthWindowController = nil
                self?.updateStatusIcon()
            })
        }
        quickAuthWindowController?.showWindow(nil)
        quickAuthWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func handleOpenOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(paths: paths, onComplete: { [weak self] in
                self?.onboardingWindowController = nil
                self?.updateStatusIcon()
            })
        }
        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc public func handleOpenAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(paths: paths)
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleOpenURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func handleCopyPublicLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        pasteboard.writeObjects([url as NSURL])

        AppNotificationCenter.shared.deliverNotification(
            title: "Public Link Copied",
            body: "Anyone can view and share this screenshot without logging in."
        )
    }

    @objc private func handleCopyImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        AppNotificationCenter.shared.deliverNotification(
            title: "Screenshot Copied",
            body: "Image copied to clipboard ready to paste."
        )
    }

    @objc private func handleCopyShareableLink(_ sender: NSMenuItem) {
        handleCopyPublicLink(sender)
    }

    @objc private func handleRevealFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func handleConnectWithClipboardToken() {
        guard let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else { return }
        Task {
            let api = RaindropAPI()
            guard (try? await api.testConnection(token: clip)) == true else {
                await MainActor.run {
                    self.handleOpenAuth()
                }
                return
            }

            let keychain = KeychainHelper()
            try? keychain.saveToken(clip)

            var settings = Settings.load(from: self.paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
            settings.setupCompleted = true
            settings.tokenGeneration += 1
            try? settings.save(to: self.paths)

            var status = WorkerStatus.load(from: self.paths) ?? WorkerStatus(health: .ok)
            status.health = .ok
            status.message = "Authenticated"
            try? status.save(to: self.paths)

            LaunchAgentManager(paths: self.paths).triggerImmediateRun()

            await MainActor.run {
                self.updateStatusIcon()
            }
        }
    }

    @objc private func handleShowSweepProgress() {
        SweepProgressWindowController.shared.showProgressWindow()
    }

    @objc private func handleToggleSweepPause() {
        if let status = SweepStatus.load(from: paths) {
            var updated = status
            if status.state == .paused {
                updated.state = .running
            } else {
                updated.state = .paused
            }
            try? updated.save(to: paths)
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(AppIdentity.sweepStatusNotification),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            updateStatusIcon()
        }
    }

    @objc private func handleStartSweepFromMenu() {
        SweepProgressWindowController.shared.startSweep()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func timeAgoString(from date: Date) -> String {
        let interval = Int(Date().timeIntervalSince(date))
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = interval / 60
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = interval / 3600
            return "\(hours)h ago"
        } else {
            let days = interval / 86400
            return "\(days)d ago"
        }
    }
}
