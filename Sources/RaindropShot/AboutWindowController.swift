import AppKit
import RaindropShotCore

@MainActor
public final class AboutWindowController: NSWindowController {
    private let paths: AppPaths

    public init(paths: AppPaths = .standard) {
        self.paths = paths

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About RaindropShot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let window = window else { return }

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 350))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        // App Icon
        let iconView = NSImageView(frame: NSRect(x: 180, y: 250, width: 60, height: 60))
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        if let icon = NSImage(systemSymbolName: "camera.metering.matrix", accessibilityDescription: "RaindropShot")?.withSymbolConfiguration(config) {
            iconView.image = icon
            iconView.contentTintColor = .controlAccentColor
        }
        visualEffect.addSubview(iconView)

        // Title & Version
        let titleLabel = makeLabel(text: "RaindropShot", frame: NSRect(x: 20, y: 215, width: 380, height: 26), alignment: .center)
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        visualEffect.addSubview(titleLabel)

        let versionLabel = makeLabel(text: "Version 1.0.0 (Native Swift)", frame: NSRect(x: 20, y: 196, width: 380, height: 18), alignment: .center)
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(versionLabel)

        // Architecture Card
        let card = NSBox(frame: NSRect(x: 35, y: 70, width: 350, height: 118))
        card.boxType = .custom
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        card.borderWidth = 1.0
        card.cornerRadius = 8.0

        let stat1 = makeLabel(text: "⚡️ Idle Worker Memory:", frame: NSRect(x: 16, y: 78, width: 170, height: 18))
        stat1.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let val1 = makeLabel(text: "0 MB (Terminates on exit)", frame: NSRect(x: 180, y: 78, width: 154, height: 18), alignment: .right)
        val1.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        val1.textColor = .systemGreen

        let stat2 = makeLabel(text: "⏱ Idle CPU Usage:", frame: NSRect(x: 16, y: 48, width: 170, height: 18))
        stat2.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let val2 = makeLabel(text: "0.0% (Zero disk watchers)", frame: NSRect(x: 180, y: 48, width: 154, height: 18), alignment: .right)
        val2.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        val2.textColor = .systemGreen

        let stat3 = makeLabel(text: "🔐 Token Storage:", frame: NSRect(x: 16, y: 18, width: 170, height: 18))
        stat3.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let val3 = makeLabel(text: "macOS Keychain Services", frame: NSRect(x: 180, y: 18, width: 154, height: 18), alignment: .right)
        val3.font = NSFont.systemFont(ofSize: 11, weight: .semibold)

        card.addSubview(stat1)
        card.addSubview(val1)
        card.addSubview(stat2)
        card.addSubview(val2)
        card.addSubview(stat3)
        card.addSubview(val3)
        visualEffect.addSubview(card)

        // Links
        let githubBtn = NSButton(title: "GitHub", target: self, action: #selector(handleOpenGitHub))
        githubBtn.frame = NSRect(x: 95, y: 24, width: 100, height: 26)
        githubBtn.bezelStyle = .rounded
        visualEffect.addSubview(githubBtn)

        let raindropBtn = NSButton(title: "Raindrop.io", target: self, action: #selector(handleOpenRaindrop))
        raindropBtn.frame = NSRect(x: 225, y: 24, width: 100, height: 26)
        raindropBtn.bezelStyle = .rounded
        visualEffect.addSubview(raindropBtn)

        window.contentView = visualEffect
    }

    @objc private func handleOpenGitHub() {
        if let url = URL(string: "https://github.com/tejxv/raindrop-screenshot-automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleOpenRaindrop() {
        if let url = URL(string: "https://raindrop.io") {
            NSWorkspace.shared.open(url)
        }
    }

    private func makeLabel(text: String, frame: NSRect, alignment: NSTextAlignment = .natural) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = alignment
        return label
    }
}
