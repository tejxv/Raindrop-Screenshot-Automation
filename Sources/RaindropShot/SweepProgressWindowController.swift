import AppKit
import RaindropShotCore

@MainActor
public final class SweepProgressWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SweepProgressWindowController()

    private let paths: AppPaths
    private var coordinator: SweepCoordinator?
    private var pollTimer: Timer?
    private var currentStatus: SweepStatus?
    private var isSweepTaskRunning: Bool = false

    // UI Elements
    private var titleLabel: NSTextField!
    private var counterLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var phaseLabel: NSTextField!
    private var metricsLabel: NSTextField!
    private var pauseResumeButton: NSButton!
    private var stopButton: NSButton!
    private var doneButton: NSButton!

    public init(paths: AppPaths = .standard) {
        self.paths = paths

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Organize Screenshots"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        buildUI()
        registerNotifications()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let window = window else { return }

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .underWindowBackground
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]

        // 1. Header Title
        titleLabel = NSTextField(labelWithString: "Organizing your screenshots")
        titleLabel.frame = NSRect(x: 32, y: 206, width: 416, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .labelColor
        visualEffect.addSubview(titleLabel)

        // 2. Large Primary Counter (e.g. "72 of 184")
        counterLabel = NSTextField(labelWithString: "0 of 0")
        counterLabel.frame = NSRect(x: 32, y: 164, width: 416, height: 36)
        counterLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        counterLabel.textColor = .labelColor
        counterLabel.setAccessibilityRole(.staticText)
        visualEffect.addSubview(counterLabel)

        // 3. Native Progress Bar
        progressBar = NSProgressIndicator(frame: NSRect(x: 32, y: 140, width: 416, height: 14))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 100.0
        progressBar.doubleValue = 0.0
        visualEffect.addSubview(progressBar)

        // 4. Current State Subtitle (e.g. "Creating descriptive names…")
        phaseLabel = NSTextField(labelWithString: "Finding screenshots…")
        phaseLabel.frame = NSRect(x: 32, y: 112, width: 416, height: 20)
        phaseLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        phaseLabel.textColor = .secondaryLabelColor
        visualEffect.addSubview(phaseLabel)

        // 5. Compact Metrics (e.g. "112 remaining · 68 uploaded · 4 skipped")
        metricsLabel = NSTextField(labelWithString: "0 remaining · 0 uploaded · 0 skipped")
        metricsLabel.frame = NSRect(x: 32, y: 90, width: 416, height: 18)
        metricsLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        metricsLabel.textColor = .tertiaryLabelColor
        visualEffect.addSubview(metricsLabel)

        // Divider
        let separator = NSBox(frame: NSRect(x: 32, y: 72, width: 416, height: 1))
        separator.boxType = .separator
        visualEffect.addSubview(separator)

        // 6. Action Controls Bar
        pauseResumeButton = NSButton(title: "Pause", target: self, action: #selector(handlePauseResume))
        pauseResumeButton.frame = NSRect(x: 32, y: 22, width: 90, height: 32)
        pauseResumeButton.bezelStyle = .rounded
        visualEffect.addSubview(pauseResumeButton)

        stopButton = NSButton(title: "Stop Sweep", target: self, action: #selector(handleStop))
        stopButton.frame = NSRect(x: 128, y: 22, width: 104, height: 32)
        stopButton.bezelStyle = .rounded
        visualEffect.addSubview(stopButton)

        doneButton = NSButton(title: "Done", target: self, action: #selector(handleDone))
        doneButton.frame = NSRect(x: 366, y: 22, width: 82, height: 32)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.isHidden = true
        visualEffect.addSubview(doneButton)

        window.contentView = visualEffect
    }

    // MARK: - Notification & Observation

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSweepNotification(_:)),
            name: NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSweepNotification(_:)),
            name: NSNotification.Name(AppIdentity.sweepStatusNotification),
            object: nil
        )
    }

    @objc private func handleSweepNotification(_ notification: Notification) {
        Task { @MainActor in
            if let status = notification.object as? SweepStatus {
                self.updateUI(with: status)
            } else if let status = SweepStatus.load(from: self.paths) {
                self.updateUI(with: status)
            }
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        startPolling()
    }

    public func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        if let status = SweepStatus.load(from: paths) {
            updateUI(with: status)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if let status = SweepStatus.load(from: self.paths) {
                    self.updateUI(with: status)
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Public Triggers

    public func startSweep(coordinator: SweepCoordinator? = nil) {
        self.coordinator = coordinator ?? SweepCoordinator(paths: paths)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()

        guard !isSweepTaskRunning else { return }
        isSweepTaskRunning = true

        Task.detached(priority: .userInitiated) { [coordinator = self.coordinator] in
            guard let coord = coordinator else { return }
            let finalStatus = await coord.runSweep()
            await MainActor.run {
                self.isSweepTaskRunning = false
                self.updateUI(with: finalStatus)
            }
        }
    }

    public func showProgressWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    // MARK: - UI Updates

    private func updateUI(with status: SweepStatus) {
        self.currentStatus = status

        // Update accessibility
        counterLabel.setAccessibilityValue(status.accessibilityValue)

        // Counter
        if status.total > 0 {
            counterLabel.stringValue = "\(status.completed) of \(status.total)"
            progressBar.isIndeterminate = false
            progressBar.minValue = 0.0
            progressBar.maxValue = Double(status.total)
            progressBar.doubleValue = Double(status.completed)
            progressBar.needsDisplay = true
        } else {
            counterLabel.stringValue = "0 of 0"
            progressBar.isIndeterminate = (status.state == .running && status.phase == .discovering)
            progressBar.doubleValue = 0.0
            progressBar.needsDisplay = true
        }

        // Metrics: "112 remaining · 68 uploaded · 4 skipped"
        let metricsStr = "\(status.remaining) remaining · \(status.uploaded) uploaded · \(status.skipped) skipped"
        metricsLabel.stringValue = metricsStr

        // Phase & Title
        switch status.state {
        case .idle:
            titleLabel.stringValue = "Organize Screenshots"
            phaseLabel.stringValue = "Ready to organize existing screenshots."
            pauseResumeButton.isEnabled = false
            stopButton.isEnabled = false
            doneButton.isHidden = true

        case .running:
            titleLabel.stringValue = "Organizing your screenshots"
            phaseLabel.stringValue = status.phase.title
            pauseResumeButton.isEnabled = true
            pauseResumeButton.title = "Pause"
            stopButton.isEnabled = true
            doneButton.isHidden = true

        case .paused:
            titleLabel.stringValue = "Sweep Paused"
            phaseLabel.stringValue = "Paused · Click Resume to continue."
            pauseResumeButton.isEnabled = true
            pauseResumeButton.title = "Resume"
            stopButton.isEnabled = true
            doneButton.isHidden = true

        case .waitingForPower:
            titleLabel.stringValue = "Waiting for Power"
            phaseLabel.stringValue = "Smart naming will resume when plugged into power."
            pauseResumeButton.isEnabled = true
            pauseResumeButton.title = "Pause"
            stopButton.isEnabled = true
            doneButton.isHidden = true

        case .waitingForConnection:
            titleLabel.stringValue = "Waiting for Network"
            phaseLabel.stringValue = "Will resume when internet connection is restored."
            pauseResumeButton.isEnabled = true
            pauseResumeButton.title = "Pause"
            stopButton.isEnabled = true
            doneButton.isHidden = true

        case .authRequired:
            titleLabel.stringValue = "Authentication Required"
            phaseLabel.stringValue = "Please connect to Raindrop in Settings."
            pauseResumeButton.isEnabled = false
            stopButton.isEnabled = false
            doneButton.isHidden = false

        case .stopped:
            titleLabel.stringValue = "Sweep Stopped"
            phaseLabel.stringValue = "\(status.uploaded) screenshots organized before stopping."
            pauseResumeButton.isEnabled = false
            stopButton.isEnabled = false
            doneButton.isHidden = false

        case .completed:
            titleLabel.stringValue = "Screenshots Organized"
            phaseLabel.stringValue = "\(status.uploaded) screenshots organized and synced."
            pauseResumeButton.isEnabled = false
            stopButton.isEnabled = false
            doneButton.isHidden = false

        case .failed:
            titleLabel.stringValue = "Sweep Incomplete"
            phaseLabel.stringValue = status.message ?? "An error occurred during sweep."
            pauseResumeButton.isEnabled = false
            stopButton.isEnabled = false
            doneButton.isHidden = false
        }
    }

    public func updateUIForTesting(with status: SweepStatus) {
        updateUI(with: status)
    }

    // MARK: - Actions

    @objc private func handlePauseResume() {
        guard let status = currentStatus else { return }
        if status.state == .paused {
            coordinator?.resume()
        } else {
            coordinator?.pause()
        }
    }

    @objc private func handleStop() {
        coordinator?.requestStop()
        SweepCoordinator.requestStop(paths: paths)
        stopButton.isEnabled = false
    }

    @objc private func handleDone() {
        close()
    }
}
