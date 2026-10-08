import AppKit
import RaindropShotCore

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let paths: AppPaths
    private let onDismiss: () -> Void
    private let keychain = KeychainHelper()
    private let agentManager: LaunchAgentManager
    private let raindropAPI: RaindropAPIType

    private var settings: Settings

    // UI Elements - Sync
    private var folderPathField: NSTextField!
    private var detectionPopUp: NSPopUpButton!
    private var uploadDelayPopUp: NSPopUpButton!
    private var copyScreenshotCheckbox: NSButton!
    private var copyLinkCheckbox: NSButton!
    private var pausedCheckbox: NSButton!

    // UI Elements - Storage
    private var retentionPopUp: NSPopUpButton!
    private var cleanupPopUp: NSPopUpButton!
    private var cleanStatusLabel: NSTextField!
    private var sweepBtn: NSButton!
    private var sweepStatusLabel: NSTextField!

    // UI Elements - Raindrop
    private var tokenField: NSSecureTextField!
    private var collectionIdField: NSTextField!
    private var tagsField: NSTextField!
    private var testStatusLabel: NSTextField!

    // UI Elements - Smart Naming
    private var smartNamingPopUp: NSPopUpButton!
    private var smartNamingApplyToPopUp: NSPopUpButton!
    private var smartNamingPowerCheckbox: NSButton!
    private var smartNamingStatusLabel: NSTextField!
    private var smartNamingInfoLabel: NSTextField!

    // UI Elements - Advanced
    private var cadencePopUp: NSPopUpButton!
    private var agentStatusLabel: NSTextField!
    private var notifyCheckbox: NSButton!
    private var migrationStatusLabel: NSTextField!

    public init(paths: AppPaths = .standard, onDismiss: @escaping () -> Void = {}) {
        self.paths = paths
        self.onDismiss = onDismiss
        self.agentManager = LaunchAgentManager(paths: paths)
        self.raindropAPI = RaindropAPI()
        self.settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 515, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RaindropShot Settings"
        window.center()
        window.contentMinSize = NSSize(width: 515, height: 260)
        window.contentMaxSize = NSSize(width: 515, height: 260)

        super.init(window: window)
        window.delegate = self

        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowWillClose(_ notification: Notification) {
        saveValues()
        onDismiss()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let window = window else { return }

        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        tabViewController.canPropagateSelectedChildViewControllerTitle = false

        let contentSize = NSSize(width: 515, height: 260)

        // Tab 1: Sync
        let syncVC = NSViewController()
        syncVC.title = "Sync"
        syncVC.view = createSyncView()
        syncVC.preferredContentSize = contentSize
        let syncTab = NSTabViewItem(viewController: syncVC)
        syncTab.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
        tabViewController.addTabViewItem(syncTab)

        // Tab 2: Storage
        let storageVC = NSViewController()
        storageVC.title = "Storage"
        storageVC.view = createStorageView()
        storageVC.preferredContentSize = contentSize
        let storageTab = NSTabViewItem(viewController: storageVC)
        storageTab.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Storage")
        tabViewController.addTabViewItem(storageTab)

        // Tab 3: Raindrop
        let raindropVC = NSViewController()
        raindropVC.title = "Raindrop"
        raindropVC.view = createRaindropView()
        raindropVC.preferredContentSize = contentSize
        let raindropTab = NSTabViewItem(viewController: raindropVC)
        raindropTab.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Raindrop")
        tabViewController.addTabViewItem(raindropTab)

        // Tab 4: Smart Naming
        let smartNamingVC = NSViewController()
        smartNamingVC.title = "Smart Naming"
        smartNamingVC.view = createSmartNamingView()
        smartNamingVC.preferredContentSize = contentSize
        let smartNamingTab = NSTabViewItem(viewController: smartNamingVC)
        smartNamingTab.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Smart Naming")
        tabViewController.addTabViewItem(smartNamingTab)

        // Tab 5: Advanced
        let advVC = NSViewController()
        advVC.title = "Advanced"
        advVC.view = createAdvancedView()
        advVC.preferredContentSize = contentSize
        let advTab = NSTabViewItem(viewController: advVC)
        advTab.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Advanced")
        tabViewController.addTabViewItem(advTab)

        window.contentViewController = tabViewController
    }

    public func selectTabForTesting(_ index: Int) {
        if let tabVC = window?.contentViewController as? NSTabViewController {
            tabVC.selectedTabViewItemIndex = index
            tabVC.view.layoutSubtreeIfNeeded()
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    // MARK: - View Creation Helpers

    private func createContainerView() -> NSView {
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 515, height: 260))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }

    // MARK: - Sync Tab

    private func createSyncView() -> NSView {
        let view = createContainerView()

        let folderLabel = makeLabel(text: "Screenshot Folder:", frame: NSRect(x: 20, y: 218, width: 140, height: 20), alignment: .right)
        folderPathField = NSTextField(frame: NSRect(x: 170, y: 216, width: 228, height: 22))
        folderPathField.isEditable = false
        folderPathField.lineBreakMode = .byTruncatingHead

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(handleChooseFolder))
        chooseBtn.frame = NSRect(x: 406, y: 214, width: 88, height: 26)

        let detectLabel = makeLabel(text: "Detection:", frame: NSRect(x: 20, y: 178, width: 140, height: 20), alignment: .right)
        detectionPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 176, width: 235, height: 25))
        for mode in DetectionMode.allCases {
            detectionPopUp.addItem(withTitle: mode.title)
        }

        let delayLabel = makeLabel(text: "Upload Delay:", frame: NSRect(x: 20, y: 138, width: 140, height: 20), alignment: .right)
        uploadDelayPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 136, width: 235, height: 25))
        for delay in UploadDelay.allCases {
            uploadDelayPopUp.addItem(withTitle: delay.title)
        }

        copyScreenshotCheckbox = NSButton(checkboxWithTitle: "Copy screenshot to clipboard when captured", target: self, action: #selector(handleFieldValueChanged))
        copyScreenshotCheckbox.frame = NSRect(x: 170, y: 96, width: 330, height: 20)

        copyLinkCheckbox = NSButton(checkboxWithTitle: "Copy public link to clipboard after upload", target: self, action: #selector(handleFieldValueChanged))
        copyLinkCheckbox.frame = NSRect(x: 170, y: 66, width: 330, height: 20)

        pausedCheckbox = NSButton(checkboxWithTitle: "Pause automatic sync", target: self, action: #selector(handleFieldValueChanged))
        pausedCheckbox.frame = NSRect(x: 170, y: 36, width: 330, height: 20)

        view.addSubview(folderLabel)
        view.addSubview(folderPathField)
        view.addSubview(chooseBtn)
        view.addSubview(detectLabel)
        view.addSubview(detectionPopUp)
        view.addSubview(delayLabel)
        view.addSubview(uploadDelayPopUp)
        view.addSubview(copyScreenshotCheckbox)
        view.addSubview(copyLinkCheckbox)
        view.addSubview(pausedCheckbox)

        return view
    }

    // MARK: - Storage Tab

    private func createStorageView() -> NSView {
        let view = createContainerView()

        let retentionLabel = makeLabel(text: "Keep Local Copy For:", frame: NSRect(x: 20, y: 208, width: 140, height: 20), alignment: .right)
        retentionPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 206, width: 220, height: 25))
        for ret in Retention.allCases {
            retentionPopUp.addItem(withTitle: ret.title)
        }

        let cleanupLabel = makeLabel(text: "Cleanup Action:", frame: NSRect(x: 20, y: 166, width: 140, height: 20), alignment: .right)
        cleanupPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 164, width: 220, height: 25))
        for act in CleanupAction.allCases {
            cleanupPopUp.addItem(withTitle: act.title)
        }

        let cleanNowBtn = NSButton(title: "Clean Up Uploaded Now", target: self, action: #selector(handleCleanUpNow))
        cleanNowBtn.frame = NSRect(x: 170, y: 122, width: 180, height: 26)

        cleanStatusLabel = makeLabel(text: "", frame: NSRect(x: 358, y: 125, width: 95, height: 20))
        cleanStatusLabel.font = NSFont.systemFont(ofSize: 11)

        let separator = NSBox(frame: NSRect(x: 20, y: 104, width: 475, height: 1))
        separator.boxType = .separator
        view.addSubview(separator)

        let sweepLabel = makeLabel(text: "Backlog Sweep:", frame: NSRect(x: 20, y: 64, width: 140, height: 20), alignment: .right)
        sweepBtn = NSButton(title: "Sweep Existing Screenshots…", target: self, action: #selector(handleStartSweep))
        sweepBtn.frame = NSRect(x: 170, y: 62, width: 220, height: 26)

        sweepStatusLabel = makeLabel(text: "Organize and sync screenshots created before setup.", frame: NSRect(x: 170, y: 38, width: 310, height: 20), wraps: false)
        sweepStatusLabel.textColor = .secondaryLabelColor
        sweepStatusLabel.font = NSFont.systemFont(ofSize: 11)

        view.addSubview(retentionLabel)
        view.addSubview(retentionPopUp)
        view.addSubview(cleanupLabel)
        view.addSubview(cleanupPopUp)
        view.addSubview(cleanNowBtn)
        view.addSubview(cleanStatusLabel)
        view.addSubview(sweepLabel)
        view.addSubview(sweepBtn)
        view.addSubview(sweepStatusLabel)

        updateSweepButtonDisplay()

        return view
    }

    // MARK: - Raindrop Tab

    private func createRaindropView() -> NSView {
        let view = createContainerView()

        let tokenLabel = makeLabel(text: "API Access Token:", frame: NSRect(x: 20, y: 208, width: 140, height: 20), alignment: .right)
        tokenField = NSSecureTextField(frame: NSRect(x: 170, y: 206, width: 205, height: 22))
        tokenField.placeholderString = "Paste Raindrop token"

        let testBtn = NSButton(title: "Test", target: self, action: #selector(handleTestConnection))
        testBtn.frame = NSRect(x: 382, y: 204, width: 68, height: 26)

        testStatusLabel = makeLabel(text: "", frame: NSRect(x: 170, y: 186, width: 280, height: 16))
        testStatusLabel.font = NSFont.systemFont(ofSize: 11)

        let colLabel = makeLabel(text: "Collection ID:", frame: NSRect(x: 20, y: 148, width: 140, height: 20), alignment: .right)
        collectionIdField = NSTextField(frame: NSRect(x: 170, y: 146, width: 205, height: 22))
        collectionIdField.placeholderString = "Empty for Unsorted"

        let tagsLabel = makeLabel(text: "Tags:", frame: NSRect(x: 20, y: 106, width: 140, height: 20), alignment: .right)
        tagsField = NSTextField(frame: NSRect(x: 170, y: 104, width: 205, height: 22))
        tagsField.placeholderString = "screenshot, macos"

        let tokenHelp = makeLabel(text: "Token is saved securely in your macOS Keychain.", frame: NSRect(x: 170, y: 50, width: 280, height: 28))
        tokenHelp.textColor = .secondaryLabelColor
        tokenHelp.font = NSFont.systemFont(ofSize: 11)

        view.addSubview(tokenLabel)
        view.addSubview(tokenField)
        view.addSubview(testBtn)
        view.addSubview(testStatusLabel)
        view.addSubview(colLabel)
        view.addSubview(collectionIdField)
        view.addSubview(tagsLabel)
        view.addSubview(tagsField)
        view.addSubview(tokenHelp)

        return view
    }

    // MARK: - Smart Naming Tab

    private func createSmartNamingView() -> NSView {
        let view = createContainerView()

        let modeLabel = makeLabel(text: "Smart Naming:", frame: NSRect(x: 20, y: 208, width: 140, height: 20), alignment: .right)
        smartNamingPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 206, width: 250, height: 25))
        for mode in SmartNamingMode.allCases {
            smartNamingPopUp.addItem(withTitle: mode.title)
        }

        let applyLabel = makeLabel(text: "Apply Name To:", frame: NSRect(x: 20, y: 166, width: 140, height: 20), alignment: .right)
        smartNamingApplyToPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 164, width: 250, height: 25))
        for target in SmartNamingApplyTo.allCases {
            smartNamingApplyToPopUp.addItem(withTitle: target.title)
        }

        smartNamingPowerCheckbox = NSButton(checkboxWithTitle: "Only run smart naming while connected to power", target: self, action: #selector(handleFieldValueChanged))
        smartNamingPowerCheckbox.frame = NSRect(x: 170, y: 126, width: 330, height: 20)

        smartNamingStatusLabel = makeLabel(text: "", frame: NSRect(x: 170, y: 88, width: 330, height: 24))
        smartNamingStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)

        smartNamingInfoLabel = makeLabel(
            text: "100% on-device using Apple Intelligence. Screenshot contents are never sent to external servers or third-party AI APIs.",
            frame: NSRect(x: 170, y: 34, width: 320, height: 42),
            wraps: true
        )
        smartNamingInfoLabel.textColor = .secondaryLabelColor
        smartNamingInfoLabel.font = NSFont.systemFont(ofSize: 11)

        view.addSubview(modeLabel)
        view.addSubview(smartNamingPopUp)
        view.addSubview(applyLabel)
        view.addSubview(smartNamingApplyToPopUp)
        view.addSubview(smartNamingPowerCheckbox)
        view.addSubview(smartNamingStatusLabel)
        view.addSubview(smartNamingInfoLabel)

        return view
    }

    // MARK: - Advanced Tab

    private func createAdvancedView() -> NSView {
        let view = createContainerView()

        let cadenceLabel = makeLabel(text: "Worker Cadence:", frame: NSRect(x: 20, y: 208, width: 140, height: 20), alignment: .right)
        cadencePopUp = NSPopUpButton(frame: NSRect(x: 170, y: 206, width: 165, height: 25))
        for cad in Cadence.allCases {
            cadencePopUp.addItem(withTitle: cad.title)
        }

        let agentBtn = NSButton(title: "Update Agent", target: self, action: #selector(handleUpdateAgent))
        agentBtn.frame = NSRect(x: 343, y: 204, width: 107, height: 26)

        agentStatusLabel = makeLabel(text: "", frame: NSRect(x: 170, y: 186, width: 280, height: 16))
        agentStatusLabel.font = NSFont.systemFont(ofSize: 11)

        notifyCheckbox = NSButton(checkboxWithTitle: "Show notifications for successful uploads", target: self, action: #selector(handleFieldValueChanged))
        notifyCheckbox.frame = NSRect(x: 170, y: 146, width: 280, height: 20)

        let migrateBtn = NSButton(title: "Migrate / Remove Legacy Daemon", target: self, action: #selector(handleMigrateLegacy))
        migrateBtn.frame = NSRect(x: 170, y: 96, width: 240, height: 26)

        migrationStatusLabel = makeLabel(text: "", frame: NSRect(x: 170, y: 74, width: 280, height: 16))
        migrationStatusLabel.font = NSFont.systemFont(ofSize: 11)

        let openDataBtn = NSButton(title: "Show App Support Folder", target: self, action: #selector(handleOpenAppSupport))
        openDataBtn.frame = NSRect(x: 170, y: 35, width: 200, height: 24)

        view.addSubview(cadenceLabel)
        view.addSubview(cadencePopUp)
        view.addSubview(agentBtn)
        view.addSubview(agentStatusLabel)
        view.addSubview(notifyCheckbox)
        view.addSubview(migrateBtn)
        view.addSubview(migrationStatusLabel)
        view.addSubview(openDataBtn)

        return view
    }

    // MARK: - Data Binding

    private func loadValues() {
        folderPathField.stringValue = settings.screenshotFolder

        if let idx = DetectionMode.allCases.firstIndex(of: settings.detection) {
            detectionPopUp.selectItem(at: idx)
        }

        if let idx = UploadDelay.allCases.firstIndex(of: settings.uploadDelay) {
            uploadDelayPopUp.selectItem(at: idx)
        }

        copyScreenshotCheckbox.state = settings.copyScreenshotToClipboard ? .on : .off
        copyLinkCheckbox.state = settings.copyLinkToClipboardOnUpload ? .on : .off
        pausedCheckbox.state = settings.paused ? .on : .off

        if let idx = Retention.allCases.firstIndex(of: settings.retention) {
            retentionPopUp.selectItem(at: idx)
        }

        if let idx = CleanupAction.allCases.firstIndex(of: settings.cleanupAction) {
            cleanupPopUp.selectItem(at: idx)
        }

        if let token = try? keychain.readToken() {
            tokenField.stringValue = token
        }

        if let col = settings.collectionId {
            collectionIdField.stringValue = "\(col)"
        } else {
            collectionIdField.stringValue = ""
        }

        tagsField.stringValue = settings.tags.joined(separator: ", ")

        if let idx = Cadence.allCases.firstIndex(of: settings.cadence) {
            cadencePopUp.selectItem(at: idx)
        }

        if let idx = SmartNamingMode.allCases.firstIndex(of: settings.smartNaming) {
            smartNamingPopUp.selectItem(at: idx)
        }

        if let idx = SmartNamingApplyTo.allCases.firstIndex(of: settings.smartNamingApplyTo) {
            smartNamingApplyToPopUp.selectItem(at: idx)
        }

        smartNamingPowerCheckbox.state = settings.smartNamingOnlyOnPower ? .on : .off
        updateSmartNamingStatusDisplay()

        notifyCheckbox.state = settings.notifyOnSuccess ? .on : .off

        updateAgentStatusDisplay()
        updateSweepButtonDisplay()
    }

    private func saveValues() {
        settings.screenshotFolder = folderPathField.stringValue

        let detectIndex = detectionPopUp.indexOfSelectedItem
        if detectIndex >= 0 && detectIndex < DetectionMode.allCases.count {
            settings.detection = DetectionMode.allCases[detectIndex]
        }

        let delayIndex = uploadDelayPopUp.indexOfSelectedItem
        if delayIndex >= 0 && delayIndex < UploadDelay.allCases.count {
            settings.uploadDelay = UploadDelay.allCases[delayIndex]
        }

        settings.copyScreenshotToClipboard = (copyScreenshotCheckbox.state == .on)
        settings.copyLinkToClipboardOnUpload = (copyLinkCheckbox.state == .on)
        settings.paused = (pausedCheckbox.state == .on)

        let retIndex = retentionPopUp.indexOfSelectedItem
        if retIndex >= 0 && retIndex < Retention.allCases.count {
            settings.retention = Retention.allCases[retIndex]
        }

        let cleanIndex = cleanupPopUp.indexOfSelectedItem
        if cleanIndex >= 0 && cleanIndex < CleanupAction.allCases.count {
            settings.cleanupAction = CleanupAction.allCases[cleanIndex]
        }

        let namingIndex = smartNamingPopUp.indexOfSelectedItem
        if namingIndex >= 0 && namingIndex < SmartNamingMode.allCases.count {
            settings.smartNaming = SmartNamingMode.allCases[namingIndex]
        }

        let applyIndex = smartNamingApplyToPopUp.indexOfSelectedItem
        if applyIndex >= 0 && applyIndex < SmartNamingApplyTo.allCases.count {
            settings.smartNamingApplyTo = SmartNamingApplyTo.allCases[applyIndex]
        }

        settings.smartNamingOnlyOnPower = (smartNamingPowerCheckbox.state == .on)

        // Save token to Keychain if changed
        let enteredToken = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentToken = (try? keychain.readToken()) ?? ""
        if !enteredToken.isEmpty && enteredToken != currentToken {
            try? keychain.saveToken(enteredToken)
            settings.tokenGeneration += 1
        }

        let colText = collectionIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.collectionId = Int(colText)

        settings.tags = Settings.parseTags(tagsField.stringValue)

        let cadIndex = cadencePopUp.indexOfSelectedItem
        if cadIndex >= 0 && cadIndex < Cadence.allCases.count {
            settings.cadence = Cadence.allCases[cadIndex]
        }

        settings.notifyOnSuccess = (notifyCheckbox.state == .on)
        settings.setupCompleted = true

        try? settings.save(to: paths)
    }

    private func updateSmartNamingStatusDisplay() {
        let namingService = AppleFoundationModelsNamingService()
        let availability = namingService.isAvailable()
        if availability.available {
            smartNamingStatusLabel.stringValue = "✓ Apple Intelligence Ready (On-Device)"
            smartNamingStatusLabel.textColor = .systemGreen
        } else {
            let reason = availability.reason ?? "Unavailable"
            smartNamingStatusLabel.stringValue = "⚠️ Apple Intelligence unavailable: \(reason)"
            smartNamingStatusLabel.textColor = .systemOrange
        }
    }

    private func updateAgentStatusDisplay() {
        let isLoaded = agentManager.isWorkerAgentLoaded()
        if isLoaded {
            agentStatusLabel.stringValue = "✓ Background LaunchAgent is active"
            agentStatusLabel.textColor = .systemGreen
        } else {
            agentStatusLabel.stringValue = "LaunchAgent not installed or inactive"
            agentStatusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func handleChooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: folderPathField.stringValue)

        if panel.runModal() == .OK, let selected = panel.url {
            folderPathField.stringValue = selected.path
            saveValues()
        }
    }

    @objc private func handleFieldValueChanged() {
        saveValues()
    }

    @objc private func handleCleanUpNow() {
        cleanStatusLabel?.stringValue = "Cleaning…"
        cleanStatusLabel?.textColor = .secondaryLabelColor
        Task {
            let engine = WorkerEngine(paths: paths)
            let count = await engine.cleanUploadedNow()
            await MainActor.run {
                if count > 0 {
                    self.cleanStatusLabel?.stringValue = "✓ Cleaned \(count)"
                    self.cleanStatusLabel?.textColor = .systemGreen
                } else {
                    self.cleanStatusLabel?.stringValue = "0 to clean"
                    self.cleanStatusLabel?.textColor = .secondaryLabelColor
                }
            }
        }
    }

    @objc private func handleStartSweep() {
        saveValues()
        SweepProgressWindowController.shared.startSweep()
        updateSweepButtonDisplay()
    }

    private func updateSweepButtonDisplay() {
        if let status = SweepStatus.load(from: paths) {
            if status.state == .running {
                sweepBtn?.title = "Show Sweep Progress…"
                sweepStatusLabel?.stringValue = "Sweep running: \(status.completed) of \(status.total) (\(status.phase.title))"
            } else if status.state == .paused {
                sweepBtn?.title = "Show Sweep Progress…"
                sweepStatusLabel?.stringValue = "Sweep paused: \(status.completed) of \(status.total)"
            } else if status.state == .completed {
                sweepBtn?.title = "Sweep Existing Screenshots…"
                sweepStatusLabel?.stringValue = "Last sweep completed: \(status.uploaded) organized."
            } else {
                sweepBtn?.title = "Sweep Existing Screenshots…"
                sweepStatusLabel?.stringValue = "Organize and sync screenshots created before setup."
            }
        }
    }

    @objc private func handleTestConnection() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            testStatusLabel.stringValue = "Please enter a token"
            testStatusLabel.textColor = .systemRed
            return
        }

        testStatusLabel.stringValue = "Connecting…"
        testStatusLabel.textColor = .secondaryLabelColor

        Task {
            do {
                let success = try await raindropAPI.testConnection(token: token)
                if success {
                    let quota = try? await raindropAPI.getUserQuota(token: token)
                    await MainActor.run {
                        if let q = quota {
                            let quotaText = String(format: "%.1fMB / %.1fMB used", q.usedMB, q.totalMB)
                            self.testStatusLabel.stringValue = "✓ Connected (\(quotaText))"
                        } else {
                            self.testStatusLabel.stringValue = "✓ Connected successfully"
                        }
                        self.testStatusLabel.textColor = .systemGreen
                    }
                } else {
                    await MainActor.run {
                        self.testStatusLabel.stringValue = "Connection failed"
                        self.testStatusLabel.textColor = .systemRed
                    }
                }
            } catch {
                await MainActor.run {
                    self.testStatusLabel.stringValue = "Error: \(error.localizedDescription)"
                    self.testStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func handleUpdateAgent() {
        saveValues()
        let execPath = LaunchAgentManager.locateWorkerExecutable()
        let cadenceSeconds = settings.cadence.rawValue

        Task {
            do {
                try self.agentManager.installWorkerAgent(executablePath: execPath, cadenceSeconds: cadenceSeconds)
                await MainActor.run {
                    self.updateAgentStatusDisplay()
                }
            } catch {
                await MainActor.run {
                    self.agentStatusLabel.stringValue = "Install error: \(error.localizedDescription)"
                    self.agentStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func handleMigrateLegacy() {
        let result = agentManager.migrateLegacyInstallation()
        if result.legacyPlistFound {
            migrationStatusLabel.stringValue = "✓ Removed legacy launchagent"
            migrationStatusLabel.textColor = .systemGreen
            if let col = result.legacyCollectionId, collectionIdField.stringValue.isEmpty {
                collectionIdField.stringValue = "\(col)"
            }
            if let tags = result.legacyTags, tagsField.stringValue.isEmpty {
                tagsField.stringValue = tags.joined(separator: ", ")
            }
            if let folder = result.legacyScreenshotFolder, folderPathField.stringValue.isEmpty {
                folderPathField.stringValue = folder
            }
            saveValues()
        } else {
            migrationStatusLabel.stringValue = "No legacy LaunchAgent found"
            migrationStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func handleOpenAppSupport() {
        NSWorkspace.shared.open(paths.supportDirectory)
    }

    private func makeLabel(text: String, frame: NSRect, alignment: NSTextAlignment = .natural, wraps: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = alignment
        if wraps {
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }
        return label
    }
}
