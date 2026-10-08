import AppKit
import RaindropShotCore

@MainActor
public final class QuickAuthWindowController: NSWindowController, NSWindowDelegate {
    private let paths: AppPaths
    private let onDismiss: () -> Void
    private let keychain = KeychainHelper()
    private let raindropAPI = RaindropAPI()
    private let agentManager: LaunchAgentManager
    private var oauthServer: OAuthLoopbackServer?

    // UI Elements
    private var browserAuthButton: NSButton!
    private var tokenField: NSSecureTextField!
    private var connectTokenButton: NSButton!
    private var clipboardButton: NSButton!
    private var progressSpinner: NSProgressIndicator!
    private var statusLabel: NSTextField!

    public init(paths: AppPaths = .standard, onDismiss: @escaping () -> Void = {}) {
        self.paths = paths
        self.onDismiss = onDismiss
        self.agentManager = LaunchAgentManager(paths: paths)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Raindrop Authentication"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.level = .floating

        super.init(window: window)
        window.delegate = self

        buildUI()
        checkClipboardForToken()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowWillClose(_ notification: Notification) {
        oauthServer?.cancel()
        oauthServer = nil
        onDismiss()
    }

    // MARK: - UI Layout

    private func buildUI() {
        guard let window = window else { return }
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        // 1. Header Icon
        let iconView = NSImageView(frame: NSRect(x: 30, y: 245, width: 40, height: 40))
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        if let icon = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "Raindrop")?.withSymbolConfiguration(iconConfig) {
            iconView.image = icon
            iconView.contentTintColor = .controlAccentColor
        }
        visualEffect.addSubview(iconView)

        // Header Title & Subtitle
        let titleLabel = makeLabel(text: "Connect to Raindrop", frame: NSRect(x: 82, y: 260, width: 310, height: 22))
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        visualEffect.addSubview(titleLabel)

        let subtitleLabel = makeLabel(text: "Authenticate to enable seamless screenshot sync.", frame: NSRect(x: 82, y: 242, width: 310, height: 18))
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(subtitleLabel)

        // 2. Method 1: Browser OAuth Button
        browserAuthButton = NSButton(title: "Sign In with Browser (1-Click)", target: self, action: #selector(handleBrowserOAuth))
        browserAuthButton.frame = NSRect(x: 30, y: 185, width: 360, height: 34)
        browserAuthButton.bezelStyle = .rounded
        browserAuthButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        browserAuthButton.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        browserAuthButton.imagePosition = .imageLeading
        visualEffect.addSubview(browserAuthButton)

        let oauthHelp = makeLabel(text: "Opens Safari / Chrome to authorize via OAuth 2.0.", frame: NSRect(x: 34, y: 162, width: 350, height: 18))
        oauthHelp.font = NSFont.systemFont(ofSize: 11)
        oauthHelp.textColor = .secondaryLabelColor
        visualEffect.addSubview(oauthHelp)

        // 3. Separator
        let separator = NSBox(frame: NSRect(x: 30, y: 146, width: 360, height: 1))
        separator.boxType = .separator
        visualEffect.addSubview(separator)

        let orLabel = makeLabel(text: "OR ENTER API TOKEN", frame: NSRect(x: 140, y: 137, width: 140, height: 18))
        orLabel.alignment = .center
        orLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        orLabel.textColor = .tertiaryLabelColor
        visualEffect.addSubview(orLabel)

        // 4. Method 2: Manual Token
        tokenField = NSSecureTextField(frame: NSRect(x: 30, y: 98, width: 255, height: 24))
        tokenField.placeholderString = "Paste Raindrop API Token"
        visualEffect.addSubview(tokenField)

        connectTokenButton = NSButton(title: "Connect", target: self, action: #selector(handleConnectToken))
        connectTokenButton.frame = NSRect(x: 295, y: 96, width: 95, height: 28)
        connectTokenButton.bezelStyle = .rounded
        connectTokenButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        visualEffect.addSubview(connectTokenButton)

        clipboardButton = NSButton(title: "Paste from Clipboard", target: self, action: #selector(handlePasteClipboard))
        clipboardButton.frame = NSRect(x: 30, y: 68, width: 170, height: 22)
        clipboardButton.bezelStyle = .inline
        clipboardButton.font = NSFont.systemFont(ofSize: 11)
        clipboardButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        clipboardButton.imagePosition = .imageLeading
        clipboardButton.isHidden = true
        visualEffect.addSubview(clipboardButton)

        // 5. Progress & Status
        progressSpinner = NSProgressIndicator(frame: NSRect(x: 30, y: 28, width: 18, height: 18))
        progressSpinner.style = .spinning
        progressSpinner.isDisplayedWhenStopped = false
        visualEffect.addSubview(progressSpinner)

        statusLabel = makeLabel(text: "", frame: NSRect(x: 56, y: 26, width: 334, height: 22))
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        visualEffect.addSubview(statusLabel)

        window.contentView = visualEffect
    }

    private func checkClipboardForToken() {
        guard let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        if isPotentialToken(clip) {
            tokenField.stringValue = clip
            clipboardButton.isHidden = false
            clipboardButton.title = "Use Copied Token (\(clip.prefix(8))…)"
        }
    }

    private func isPotentialToken(_ str: String) -> Bool {
        return str.count >= 20 && str.count <= 64 && !str.contains(" ") && !str.contains("\n")
    }

    // MARK: - Actions

    @objc private func handlePasteClipboard() {
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            tokenField.stringValue = clip
            handleConnectToken()
        }
    }

    @objc private func handleConnectToken() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            showStatus("Please enter an API token.", isError: true)
            return
        }

        setBusy(true, message: "Validating token with Raindrop…")

        Task {
            do {
                let isValid = try await raindropAPI.testConnection(token: token)
                guard isValid else {
                    await MainActor.run {
                        self.setBusy(false)
                        self.showStatus("Invalid token. Please check and try again.", isError: true)
                    }
                    return
                }

                let quota = try? await raindropAPI.getUserQuota(token: token)
                await MainActor.run {
                    self.finishSuccessfulAuth(token: token, quota: quota)
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    self.showStatus("Connection error: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    @objc private func handleBrowserOAuth() {
        let oauth = OAuthHelper()
        guard let authURL = oauth.buildAuthorizeURL() else {
            showStatus("Failed to build authorization URL.", isError: true)
            return
        }

        setBusy(true, message: "Waiting for approval in browser… (Port 7890)")
        NSWorkspace.shared.open(authURL)

        let server = OAuthLoopbackServer(port: 7890)
        self.oauthServer = server

        Task {
            do {
                let code = try await server.waitForCode()
                await MainActor.run {
                    self.showStatus("Exchanging authorization code…", isError: false)
                }
                let resp = try await oauth.exchangeCode(
                    code: code,
                    clientId: OAuthHelper.defaultClientId,
                    clientSecret: OAuthHelper.defaultClientSecret
                )
                let token = resp.access_token
                let quota = try? await raindropAPI.getUserQuota(token: token)
                await MainActor.run {
                    self.finishSuccessfulAuth(token: token, quota: quota)
                }
            } catch {
                await MainActor.run {
                    self.setBusy(false)
                    if error.localizedDescription.contains("Cancelled") {
                        self.showStatus("Authorization cancelled.", isError: false)
                    } else {
                        self.showStatus("OAuth error: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        }
    }

    // MARK: - Success Handling

    private func finishSuccessfulAuth(token: String, quota: UserQuota?) {
        do {
            try keychain.saveToken(token)

            var settings = Settings.load(from: paths) ?? Settings(screenshotFolder: ScreenshotLocation.defaultFolder().path)
            settings.setupCompleted = true
            settings.tokenGeneration += 1
            try settings.save(to: paths)

            // Update worker status snapshot
            var status = WorkerStatus.load(from: paths) ?? WorkerStatus(health: .ok)
            status.health = .ok
            status.message = "Authenticated"
            try? status.save(to: paths)

            // Post Darwin notification so menu bar updates immediately
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName(AppIdentity.statusNotification as CFString),
                nil,
                nil,
                true
            )

            // Trigger worker run in background
            agentManager.triggerImmediateRun()

            setBusy(false)
            let storageStr = quota.map { String(format: " (%.1fMB used)", $0.usedMB) } ?? ""
            showStatus("✓ Connected successfully!\(storageStr)", isError: false)

            // Auto-close after brief confirmation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.close()
            }
        } catch {
            setBusy(false)
            showStatus("Failed to save to Keychain: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func setBusy(_ busy: Bool, message: String? = nil) {
        if busy {
            progressSpinner.startAnimation(nil)
            browserAuthButton.isEnabled = false
            connectTokenButton.isEnabled = false
            tokenField.isEnabled = false
            clipboardButton.isEnabled = false
        } else {
            progressSpinner.stopAnimation(nil)
            browserAuthButton.isEnabled = true
            connectTokenButton.isEnabled = true
            tokenField.isEnabled = true
            clipboardButton.isEnabled = true
        }

        if let msg = message {
            showStatus(msg, isError: false)
        }
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        if isError {
            statusLabel.textColor = .systemRed
        } else if text.starts(with: "✓") {
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func makeLabel(text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }
}
