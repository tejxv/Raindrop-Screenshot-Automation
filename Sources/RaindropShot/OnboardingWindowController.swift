import AppKit
import RaindropShotCore

@MainActor
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let paths: AppPaths
    private let onComplete: () -> Void
    private let keychain = KeychainHelper()
    private let raindropAPI = RaindropAPI()
    private let agentManager: LaunchAgentManager
    private var oauthServer: OAuthLoopbackServer?

    private var currentStep: Int = 0
    private var totalSteps: Int = 3
    private var discoveredCandidatesCount: Int = 0
    private var notNowButton: NSButton!

    // Main layout views
    private var stepContainerView: NSView!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var pageIndicatorLabel: NSTextField!

    // Step 0: Auth State & Controls
    private var step0BrowserBtn: NSButton!
    private var step0TokenField: NSSecureTextField!
    private var step0ConnectBtn: NSButton!
    private var step0StatusLabel: NSTextField!
    private var step0Spinner: NSProgressIndicator!
    private var isAuthenticated: Bool = false
    private var isTokenFieldVisible: Bool = false

    // Step 1: Preferences Controls
    private var selectedFolderURL: URL
    private var step1FolderPathLabel: NSTextField!
    private var step1FolderIconView: NSImageView!
    private var step1RetentionPopup: NSPopUpButton!
    private var step1CleanupPopup: NSPopUpButton!
    private var step1CadencePopup: NSPopUpButton!
    private var step1LaunchAtLoginCheckbox: NSButton!

    public init(paths: AppPaths = .standard, onComplete: @escaping () -> Void = {}) {
        self.paths = paths
        self.onComplete = onComplete
        self.agentManager = LaunchAgentManager(paths: paths)

        let initialSettings = Settings.load(from: paths)
        self.selectedFolderURL = initialSettings?.folderURL ?? ScreenshotLocation.defaultFolder()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to RaindropShot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        buildUI()
        checkExistingAuth()
        showStep(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowWillClose(_ notification: Notification) {
        oauthServer?.cancel()
        oauthServer = nil
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let window = window else { return }

        // Vibrant Visual Effect Background
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        // Content Container
        stepContainerView = NSView(frame: NSRect(x: 0, y: 64, width: 560, height: 376))
        visualEffect.addSubview(stepContainerView)

        // Bottom Navigation Bar
        let separator = NSBox(frame: NSRect(x: 0, y: 64, width: 560, height: 1))
        separator.boxType = .separator
        visualEffect.addSubview(separator)

        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 64))

        backButton = NSButton(title: "Back", target: self, action: #selector(handleBack))
        backButton.frame = NSRect(x: 24, y: 16, width: 85, height: 32)
        backButton.bezelStyle = .rounded
        bottomBar.addSubview(backButton)

        pageIndicatorLabel = NSTextField(labelWithString: "1 of 3")
        pageIndicatorLabel.frame = NSRect(x: 220, y: 22, width: 120, height: 20)
        pageIndicatorLabel.alignment = .center
        pageIndicatorLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pageIndicatorLabel.textColor = .secondaryLabelColor
        bottomBar.addSubview(pageIndicatorLabel)

        notNowButton = NSButton(title: "Not Now", target: self, action: #selector(handleNotNow))
        notNowButton.frame = NSRect(x: 326, y: 16, width: 94, height: 32)
        notNowButton.bezelStyle = .rounded
        notNowButton.isHidden = true
        bottomBar.addSubview(notNowButton)

        nextButton = NSButton(title: "Continue", target: self, action: #selector(handleNext))
        nextButton.frame = NSRect(x: 428, y: 16, width: 108, height: 32)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        bottomBar.addSubview(nextButton)

        visualEffect.addSubview(bottomBar)
        window.contentView = visualEffect
    }

    private func checkExistingAuth() {
        if let token = try? keychain.readToken(), !token.isEmpty {
            isAuthenticated = true
        }
    }

    // MARK: - Navigation

    private var totalStepsCount: Int {
        discoveredCandidatesCount > 0 ? 4 : 3
    }

    private func showStep(_ step: Int) {
        currentStep = step
        stepContainerView.subviews.forEach { $0.removeFromSuperview() }

        backButton.isHidden = (step == 0)

        switch step {
        case 0:
            renderStep0WelcomeAndAuth()
            pageIndicatorLabel.stringValue = "1 of \(totalStepsCount)"
            nextButton.title = "Continue"
            nextButton.isEnabled = isAuthenticated
            notNowButton.isHidden = true

        case 1:
            renderStep1Preferences()
            pageIndicatorLabel.stringValue = "2 of \(totalStepsCount)"
            nextButton.title = "Continue"
            nextButton.isEnabled = true
            notNowButton.isHidden = true

        case 2:
            if discoveredCandidatesCount > 0 {
                renderStepSweep()
                pageIndicatorLabel.stringValue = "3 of 4"
                nextButton.title = "Start Sweep"
                nextButton.isEnabled = true
                notNowButton.isHidden = false
            } else {
                renderStep2Confirmation()
                pageIndicatorLabel.stringValue = "3 of 3"
                nextButton.title = "Start Using"
                nextButton.isEnabled = true
                notNowButton.isHidden = true
            }

        case 3:
            renderStep2Confirmation()
            pageIndicatorLabel.stringValue = "4 of 4"
            nextButton.title = "Start Using"
            nextButton.isEnabled = true
            notNowButton.isHidden = true

        default:
            break
        }
    }

    public func showStepForTesting(_ step: Int) {
        showStep(step)
    }

    public func setDiscoveredCandidatesCountForTesting(_ count: Int) {
        discoveredCandidatesCount = count
    }

    @objc private func handleBack() {
        if currentStep == 3 {
            showStep(discoveredCandidatesCount > 0 ? 2 : 1)
        } else if currentStep == 2 {
            showStep(1)
        } else if currentStep == 1 {
            showStep(0)
        }
    }

    @objc private func handleNotNow() {
        showStep(3)
    }

    @objc private func handleNext() {
        if currentStep == 0 {
            showStep(1)
        } else if currentStep == 1 {
            savePreferences()
            let workerState = StateStore.load(paths, now: Date()).state
            let candidates = SweepCoordinator.discoverCandidates(folderURL: selectedFolderURL, state: workerState)
            discoveredCandidatesCount = candidates.count
            if discoveredCandidatesCount > 0 {
                showStep(2)
            } else {
                showStep(2)
            }
        } else if currentStep == 2 {
            if discoveredCandidatesCount > 0 {
                startSweepAndFinish()
            } else {
                finishOnboarding()
            }
        } else {
            finishOnboarding()
        }
    }

    // MARK: - Step 0: Welcome & Authentication

    private func renderStep0WelcomeAndAuth() {
        let view = NSView(frame: stepContainerView.bounds)

        // Hero Icon
        let iconView = NSImageView(frame: NSRect(x: 252, y: 295, width: 56, height: 56))
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        if let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "RaindropShot")?.withSymbolConfiguration(config) {
            iconView.image = icon
            iconView.contentTintColor = .controlAccentColor
        }
        view.addSubview(iconView)

        // Title & Tagline
        let titleLabel = makeWrappingLabel(
            text: "Welcome to RaindropShot",
            frame: NSRect(x: 30, y: 256, width: 500, height: 30),
            font: .systemFont(ofSize: 22, weight: .bold),
            alignment: .center
        )
        view.addSubview(titleLabel)

        let subtitleLabel = makeWrappingLabel(
            text: "Zero-memory, background screenshot syncing directly to Raindrop.io.",
            frame: NSRect(x: 30, y: 232, width: 500, height: 20),
            font: .systemFont(ofSize: 13, weight: .regular),
            textColor: .secondaryLabelColor,
            alignment: .center
        )
        view.addSubview(subtitleLabel)

        // Highlights Card
        let highlightsCard = NSBox(frame: NSRect(x: 50, y: 110, width: 460, height: 114))
        highlightsCard.boxType = .custom
        highlightsCard.titlePosition = .noTitle
        highlightsCard.contentViewMargins = .zero
        highlightsCard.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        highlightsCard.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        highlightsCard.borderWidth = 1.0
        highlightsCard.cornerRadius = 10.0

        let feat1 = ("bolt.fill", "Zero Idle Resource Usage", "Runs in milliseconds only when needed. 0 MB idle RAM, 0% CPU.")
        let feat2 = ("shield.fill", "Safe Local Retention", "Keeps screenshots on your desktop until confirmed, then cleans up safely.")

        renderFeatureRow(icon: feat1.0, title: feat1.1, desc: feat1.2, in: highlightsCard, y: 56)
        renderFeatureRow(icon: feat2.0, title: feat2.1, desc: feat2.2, in: highlightsCard, y: 10)

        view.addSubview(highlightsCard)

        // Auth Area Card
        let authContainer = NSView(frame: NSRect(x: 50, y: 6, width: 460, height: 98))

        if isAuthenticated {
            let successCard = NSBox(frame: NSRect(x: 0, y: 16, width: 460, height: 60))
            successCard.boxType = .custom
            successCard.fillColor = NSColor.systemGreen.withAlphaComponent(0.12)
            successCard.borderColor = NSColor.systemGreen.withAlphaComponent(0.35)
            successCard.borderWidth = 1.0
            successCard.cornerRadius = 8.0

            let checkIcon = NSImageView(frame: NSRect(x: 16, y: 20, width: 20, height: 20))
            checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            checkIcon.contentTintColor = .systemGreen
            successCard.addSubview(checkIcon)

            let authText = makeWrappingLabel(
                text: "Connected to Raindrop.io",
                frame: NSRect(x: 44, y: 20, width: 280, height: 20),
                font: .systemFont(ofSize: 13, weight: .semibold),
                textColor: .labelColor
            )
            successCard.addSubview(authText)

            let reauthBtn = NSButton(title: "Change Account…", target: self, action: #selector(handleShowTokenInput))
            reauthBtn.frame = NSRect(x: 324, y: 16, width: 124, height: 28)
            reauthBtn.bezelStyle = .rounded
            reauthBtn.font = .systemFont(ofSize: 11)
            successCard.addSubview(reauthBtn)

            authContainer.addSubview(successCard)
        } else {
            step0BrowserBtn = NSButton(title: "Sign In with Raindrop (1-Click)", target: self, action: #selector(handleStep0BrowserAuth))
            step0BrowserBtn.frame = NSRect(x: 40, y: 44, width: 380, height: 36)
            step0BrowserBtn.bezelStyle = .rounded
            step0BrowserBtn.font = .systemFont(ofSize: 13, weight: .semibold)
            step0BrowserBtn.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
            step0BrowserBtn.imagePosition = .imageLeading
            authContainer.addSubview(step0BrowserBtn)

            let manualBtn = NSButton(title: "Or connect with API token / clipboard", target: self, action: #selector(handleShowTokenInput))
            manualBtn.frame = NSRect(x: 100, y: 18, width: 260, height: 20)
            manualBtn.bezelStyle = .inline
            manualBtn.isBordered = false
            manualBtn.font = .systemFont(ofSize: 11)
            manualBtn.contentTintColor = .secondaryLabelColor
            authContainer.addSubview(manualBtn)

            step0Spinner = NSProgressIndicator(frame: NSRect(x: 220, y: 16, width: 16, height: 16))
            step0Spinner.style = .spinning
            step0Spinner.isDisplayedWhenStopped = false
            authContainer.addSubview(step0Spinner)

            step0StatusLabel = makeWrappingLabel(
                text: "",
                frame: NSRect(x: 20, y: 0, width: 420, height: 18),
                font: .systemFont(ofSize: 11),
                textColor: .secondaryLabelColor,
                alignment: .center
            )
            authContainer.addSubview(step0StatusLabel)
        }

        view.addSubview(authContainer)
        stepContainerView.addSubview(view)
    }

    private func renderFeatureRow(icon: String, title: String, desc: String, in container: NSView, y: CGFloat) {
        let target = (container as? NSBox)?.contentView ?? container
        let iconView = NSImageView(frame: NSRect(x: 16, y: y + 14, width: 20, height: 20))
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            iconView.image = img
            iconView.contentTintColor = .controlAccentColor
        }
        target.addSubview(iconView)

        let hLabel = makeWrappingLabel(
            text: title,
            frame: NSRect(x: 46, y: y + 20, width: 396, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        target.addSubview(hLabel)

        let dLabel = makeWrappingLabel(
            text: desc,
            frame: NSRect(x: 46, y: y + 2, width: 396, height: 18),
            font: .systemFont(ofSize: 11, weight: .regular),
            textColor: .secondaryLabelColor
        )
        target.addSubview(dLabel)
    }

    @objc private func handleStep0BrowserAuth() {
        let oauth = OAuthHelper()
        guard let authURL = oauth.buildAuthorizeURL() else { return }

        step0Spinner?.startAnimation(nil)
        step0BrowserBtn?.isEnabled = false
        step0StatusLabel?.stringValue = "Waiting for approval in browser… (Port 7890)"
        step0StatusLabel?.textColor = .secondaryLabelColor

        NSWorkspace.shared.open(authURL)

        let server = OAuthLoopbackServer(port: 7890)
        self.oauthServer = server

        Task {
            do {
                let code = try await server.waitForCode()
                await MainActor.run {
                    self.step0StatusLabel?.stringValue = "Authorizing with Raindrop…"
                }

                let resp = try await oauth.exchangeCode(
                    code: code,
                    clientId: OAuthHelper.defaultClientId,
                    clientSecret: OAuthHelper.defaultClientSecret
                )
                let token = resp.access_token

                await MainActor.run {
                    self.finishAuth(token: token)
                }
            } catch {
                await MainActor.run {
                    self.step0Spinner?.stopAnimation(nil)
                    self.step0BrowserBtn?.isEnabled = true
                    self.step0StatusLabel?.stringValue = "Authentication failed: \(error.localizedDescription)"
                    self.step0StatusLabel?.textColor = .systemRed
                }
            }
        }
    }

    @objc private func handleShowTokenInput() {
        // Quick input dialog for pasting token directly
        let alert = NSAlert()
        alert.messageText = "Connect Raindrop API Token"
        alert.informativeText = "Paste your Raindrop.io Test Token from Settings > Integrations."
        alert.alertStyle = .informational

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.count >= 20 && clip.count <= 64 && !clip.contains(" ") {
            input.stringValue = clip
        }
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let token = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }

            Task {
                let isValid = (try? await self.raindropAPI.testConnection(token: token)) ?? false
                if isValid {
                    await MainActor.run {
                        self.finishAuth(token: token)
                    }
                } else {
                    await MainActor.run {
                        let errAlert = NSAlert()
                        errAlert.messageText = "Invalid Token"
                        errAlert.informativeText = "Could not verify this token with Raindrop.io."
                        errAlert.runModal()
                    }
                }
            }
        }
    }

    private func finishAuth(token: String) {
        try? keychain.saveToken(token)
        isAuthenticated = true
        step0Spinner?.stopAnimation(nil)
        nextButton.isEnabled = true
        showStep(0) // Re-render step 0 with the connected badge
    }

    // MARK: - Step 1: Preferences & Screenshot Folder

    private func renderStep1Preferences() {
        let view = NSView(frame: stepContainerView.bounds)

        let titleLabel = makeWrappingLabel(
            text: "Sync & Retention Preferences",
            frame: NSRect(x: 30, y: 326, width: 500, height: 28),
            font: .systemFont(ofSize: 20, weight: .bold),
            alignment: .center
        )
        view.addSubview(titleLabel)

        let subtitleLabel = makeWrappingLabel(
            text: "Configure your screenshot directory and local cleanup behavior.",
            frame: NSRect(x: 30, y: 304, width: 500, height: 20),
            font: .systemFont(ofSize: 12, weight: .regular),
            textColor: .secondaryLabelColor,
            alignment: .center
        )
        view.addSubview(subtitleLabel)

        // Main Card
        let card = NSBox(frame: NSRect(x: 45, y: 30, width: 470, height: 260))
        card.boxType = .custom
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        card.borderWidth = 1.0
        card.cornerRadius = 10.0

        // 1. Screenshot Folder Row
        step1FolderIconView = NSImageView(frame: NSRect(x: 20, y: 206, width: 32, height: 32))
        step1FolderIconView.image = NSWorkspace.shared.icon(forFile: selectedFolderURL.path)
        card.addSubview(step1FolderIconView)

        let folderTitle = makeWrappingLabel(
            text: selectedFolderURL.lastPathComponent,
            frame: NSRect(x: 60, y: 220, width: 280, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold)
        )
        card.addSubview(folderTitle)

        step1FolderPathLabel = makeWrappingLabel(
            text: selectedFolderURL.path,
            frame: NSRect(x: 60, y: 204, width: 280, height: 16),
            font: .systemFont(ofSize: 11),
            textColor: .secondaryLabelColor
        )
        step1FolderPathLabel.lineBreakMode = .byTruncatingHead
        card.addSubview(step1FolderPathLabel)

        let chooseBtn = NSButton(title: "Change…", target: self, action: #selector(handleStep1ChooseFolder))
        chooseBtn.frame = NSRect(x: 360, y: 208, width: 90, height: 28)
        chooseBtn.bezelStyle = .rounded
        chooseBtn.font = .systemFont(ofSize: 12)
        card.addSubview(chooseBtn)

        let div1 = NSBox(frame: NSRect(x: 20, y: 194, width: 430, height: 1))
        div1.boxType = .separator
        card.addSubview(div1)

        // 2. Retention Duration
        let retLabel = makeWrappingLabel(
            text: "Keep Local Copy:",
            frame: NSRect(x: 20, y: 154, width: 140, height: 20),
            font: .systemFont(ofSize: 12, weight: .medium),
            alignment: .right
        )
        card.addSubview(retLabel)

        step1RetentionPopup = NSPopUpButton(frame: NSRect(x: 170, y: 150, width: 260, height: 26))
        for r in Retention.allCases { step1RetentionPopup.addItem(withTitle: r.title) }
        step1RetentionPopup.selectItem(withTitle: Retention.fiveMinutes.title)
        card.addSubview(step1RetentionPopup)

        // 3. Cleanup Action
        let cleanLabel = makeWrappingLabel(
            text: "Cleanup Action:",
            frame: NSRect(x: 20, y: 114, width: 140, height: 20),
            font: .systemFont(ofSize: 12, weight: .medium),
            alignment: .right
        )
        card.addSubview(cleanLabel)

        step1CleanupPopup = NSPopUpButton(frame: NSRect(x: 170, y: 110, width: 260, height: 26))
        for c in CleanupAction.allCases { step1CleanupPopup.addItem(withTitle: c.title) }
        step1CleanupPopup.selectItem(withTitle: CleanupAction.trash.title)
        card.addSubview(step1CleanupPopup)

        // 4. Background Cadence
        let cadLabel = makeWrappingLabel(
            text: "Sync Cadence:",
            frame: NSRect(x: 20, y: 74, width: 140, height: 20),
            font: .systemFont(ofSize: 12, weight: .medium),
            alignment: .right
        )
        card.addSubview(cadLabel)

        step1CadencePopup = NSPopUpButton(frame: NSRect(x: 170, y: 70, width: 260, height: 26))
        for c in Cadence.allCases { step1CadencePopup.addItem(withTitle: c.title) }
        step1CadencePopup.selectItem(withTitle: Cadence.fiveMinutes.title)
        card.addSubview(step1CadencePopup)

        let div2 = NSBox(frame: NSRect(x: 20, y: 56, width: 430, height: 1))
        div2.boxType = .separator
        card.addSubview(div2)

        // 5. Launch at login checkbox
        step1LaunchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch background worker at login (Recommended)", target: nil, action: nil)
        step1LaunchAtLoginCheckbox.frame = NSRect(x: 60, y: 22, width: 370, height: 20)
        step1LaunchAtLoginCheckbox.font = .systemFont(ofSize: 12)
        step1LaunchAtLoginCheckbox.state = .on
        card.addSubview(step1LaunchAtLoginCheckbox)

        view.addSubview(card)
        stepContainerView.addSubview(view)
    }

    @objc private func handleStep1ChooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = selectedFolderURL

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolderURL = url
            step1FolderPathLabel?.stringValue = url.path
            step1FolderIconView?.image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    // MARK: - Step 2: Confirmation & Activation

    private func renderStep2Confirmation() {
        let view = NSView(frame: stepContainerView.bounds)

        // Green Seal Icon
        let iconView = NSImageView(frame: NSRect(x: 252, y: 285, width: 56, height: 56))
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        if let icon = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "All Set")?.withSymbolConfiguration(config) {
            iconView.image = icon
            iconView.contentTintColor = .systemGreen
        }
        view.addSubview(iconView)

        let titleLabel = makeWrappingLabel(
            text: "You're All Set!",
            frame: NSRect(x: 30, y: 244, width: 500, height: 28),
            font: .systemFont(ofSize: 22, weight: .bold),
            alignment: .center
        )
        view.addSubview(titleLabel)

        let subtitleLabel = makeWrappingLabel(
            text: "RaindropShot will silently keep your screenshots backed up and organized.",
            frame: NSRect(x: 30, y: 222, width: 500, height: 20),
            font: .systemFont(ofSize: 13, weight: .regular),
            textColor: .secondaryLabelColor,
            alignment: .center
        )
        view.addSubview(subtitleLabel)

        // Summary Card
        let card = NSBox(frame: NSRect(x: 50, y: 55, width: 460, height: 150))
        card.boxType = .custom
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        card.borderWidth = 1.0
        card.cornerRadius = 10.0

        let rows: [(String, String)] = [
            ("Screenshot Folder:", selectedFolderURL.path),
            ("Background Cadence:", step1CadencePopup?.titleOfSelectedItem ?? "Every 5 minutes"),
            ("Retention & Cleanup:", "\(step1RetentionPopup?.titleOfSelectedItem ?? "5 minutes") → \(step1CleanupPopup?.titleOfSelectedItem ?? "Move to Trash")"),
            ("Resource Footprint:", "0 MB idle RAM · 0.0% idle CPU")
        ]

        var currentY: CGFloat = 112
        for (label, val) in rows {
            let kLabel = makeWrappingLabel(
                text: label,
                frame: NSRect(x: 18, y: currentY, width: 154, height: 18),
                font: .systemFont(ofSize: 12, weight: .semibold),
                alignment: .right
            )
            card.addSubview(kLabel)

            let vLabel = makeWrappingLabel(
                text: val,
                frame: NSRect(x: 180, y: currentY, width: 264, height: 18),
                font: .systemFont(ofSize: 12),
                textColor: val.contains("0 MB") ? .systemGreen : .labelColor
            )
            vLabel.lineBreakMode = .byTruncatingHead
            card.addSubview(vLabel)

            currentY -= 28
        }

        view.addSubview(card)
        stepContainerView.addSubview(view)
    }

    // MARK: - Step Sweep: Organize Existing Screenshots

    private func renderStepSweep() {
        let view = NSView(frame: stepContainerView.bounds)

        // Hero Icon
        let iconView = NSImageView(frame: NSRect(x: 252, y: 295, width: 56, height: 56))
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        if let icon = NSImage(systemSymbolName: "sparkles.rectangle.stack.fill", accessibilityDescription: "Sweep")?.withSymbolConfiguration(config) {
            iconView.image = icon
            iconView.contentTintColor = .controlAccentColor
        }
        view.addSubview(iconView)

        let titleLabel = makeWrappingLabel(
            text: "Organize your existing screenshots",
            frame: NSRect(x: 30, y: 255, width: 500, height: 28),
            font: .systemFont(ofSize: 22, weight: .bold),
            alignment: .center
        )
        view.addSubview(titleLabel)

        let badgeLabel = makeWrappingLabel(
            text: "\(discoveredCandidatesCount) screenshots found",
            frame: NSRect(x: 170, y: 228, width: 220, height: 20),
            font: .systemFont(ofSize: 13, weight: .semibold),
            textColor: .controlAccentColor,
            alignment: .center
        )
        view.addSubview(badgeLabel)

        let subtitleLabel = makeWrappingLabel(
            text: "Smart naming can organize and upload your existing screenshots too.",
            frame: NSRect(x: 30, y: 202, width: 500, height: 20),
            font: .systemFont(ofSize: 13, weight: .regular),
            textColor: .secondaryLabelColor,
            alignment: .center
        )
        view.addSubview(subtitleLabel)

        // Highlights Card
        let card = NSBox(frame: NSRect(x: 50, y: 22, width: 460, height: 164))
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.contentViewMargins = .zero
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        card.borderWidth = 1.0
        card.cornerRadius = 10.0

        let feat1 = ("sparkles", "On-Device Smart Naming", "Generates concise, descriptive filenames using Apple Intelligence.")
        let feat2 = ("icloud.and.arrow.up.fill", "Seamless Raindrop Upload", "Syncs historical screenshots into your Raindrop collection.")
        let feat3 = ("lock.shield.fill", "Private & On-Device", "Zero screenshot contents sent to external third-party AI APIs.")

        renderFeatureRow(icon: feat1.0, title: feat1.1, desc: feat1.2, in: card, y: 110)
        renderFeatureRow(icon: feat2.0, title: feat2.1, desc: feat2.2, in: card, y: 62)
        renderFeatureRow(icon: feat3.0, title: feat3.1, desc: feat3.2, in: card, y: 14)

        view.addSubview(card)
        stepContainerView.addSubview(view)
    }

    // MARK: - Save & Finish (Asynchronous, Zero UI Freeze)

    private func savePreferences() {
        var settings = Settings.load(from: paths) ?? Settings(screenshotFolder: selectedFolderURL.path)
        settings.screenshotFolder = selectedFolderURL.path

        if let retIdx = step1RetentionPopup?.indexOfSelectedItem, retIdx >= 0 {
            settings.retention = Retention.allCases[retIdx]
        }
        if let cleanIdx = step1CleanupPopup?.indexOfSelectedItem, cleanIdx >= 0 {
            settings.cleanupAction = CleanupAction.allCases[cleanIdx]
        }
        if let cadIdx = step1CadencePopup?.indexOfSelectedItem, cadIdx >= 0 {
            settings.cadence = Cadence.allCases[cadIdx]
        }

        settings.setupCompleted = true
        try? settings.save(to: paths)

        var status = WorkerStatus.load(from: paths) ?? WorkerStatus(health: .ok)
        status.health = .ok
        status.message = "Setup Complete"
        try? status.save(to: paths)
    }

    private func startSweepAndFinish() {
        nextButton.isEnabled = false
        notNowButton.isEnabled = false
        nextButton.title = "Starting…"

        savePreferences()

        let installAgent = (step1LaunchAtLoginCheckbox?.state == .on)
        let settings = Settings.load(from: paths)
        let cadenceSeconds = settings?.cadence.rawValue ?? 300
        let workerPath = LaunchAgentManager.locateWorkerExecutable()

        Task.detached(priority: .userInitiated) { [agentManager = self.agentManager] in
            if installAgent {
                try? agentManager.installWorkerAgent(executablePath: workerPath, cadenceSeconds: cadenceSeconds)
            }

            await MainActor.run {
                self.onComplete()
                self.close()
                SweepProgressWindowController.shared.startSweep()
            }
        }
    }

    private func finishOnboarding() {
        nextButton.isEnabled = false
        nextButton.title = "Starting…"

        savePreferences()

        let installAgent = (step1LaunchAtLoginCheckbox?.state == .on)
        let settings = Settings.load(from: paths)
        let cadenceSeconds = settings?.cadence.rawValue ?? 300
        let workerPath = LaunchAgentManager.locateWorkerExecutable()

        // Execute background installation and kickstart in background task so UI NEVER hangs
        Task.detached(priority: .userInitiated) { [agentManager = self.agentManager] in
            if installAgent {
                try? agentManager.installWorkerAgent(executablePath: workerPath, cadenceSeconds: cadenceSeconds)
            }
            agentManager.triggerImmediateRun(executablePath: workerPath)

            await MainActor.run {
                self.onComplete()
                self.close()
            }
        }
    }

    // MARK: - Helper

    private func makeWrappingLabel(
        text: String,
        frame: NSRect,
        font: NSFont = .systemFont(ofSize: 12),
        textColor: NSColor = .labelColor,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = frame
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.font = font
        label.textColor = textColor
        label.alignment = alignment
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}
