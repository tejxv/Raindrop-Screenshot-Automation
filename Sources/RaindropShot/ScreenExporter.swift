import AppKit
import RaindropShotCore

@MainActor
public enum ScreenExporter {
    public static func exportAllScreens(to outputDir: URL, paths: AppPaths = .standard) {
        exportScreensForAppearance(name: .darkAqua, subfolder: "dark", outputDir: outputDir, paths: paths)
        exportScreensForAppearance(name: .aqua, subfolder: "light", outputDir: outputDir, paths: paths)
    }

    private static func exportScreensForAppearance(
        name appearanceName: NSAppearance.Name,
        subfolder: String,
        outputDir: URL,
        paths: AppPaths
    ) {
        let targetDir = outputDir.appendingPathComponent(subfolder)
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let appearance = NSAppearance(named: appearanceName)
        NSApp.appearance = appearance

        func saveWindow(_ window: NSWindow, name: String) {
            window.appearance = appearance
            window.contentView?.appearance = appearance
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            window.displayIfNeeded()
            guard let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()

            let rect = view.bounds
            let image = NSImage(size: rect.size)
            image.lockFocus()
            appearance?.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }

            if let rep = view.bitmapImageRepForCachingDisplay(in: rect) {
                view.cacheDisplay(in: rect, to: rep)
                rep.draw(in: rect)
            }
            image.unlockFocus()

            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let pngData = rep.representation(using: .png, properties: [:]) {
                let fileURL = targetDir.appendingPathComponent("\(name).png")
                try? pngData.write(to: fileURL)
                print("✓ Exported (\(subfolder)): \(name).png")
            }
        }

        // 1. Onboarding Steps
        let onboarding = OnboardingWindowController(paths: paths)
        if let win = onboarding.window {
            win.appearance = appearance
            onboarding.setDiscoveredCandidatesCountForTesting(184)

            onboarding.showStepForTesting(0)
            saveWindow(win, name: "01_onboarding_step1_welcome")

            onboarding.showStepForTesting(1)
            saveWindow(win, name: "02_onboarding_step2_preferences")

            onboarding.showStepForTesting(2)
            saveWindow(win, name: "03_onboarding_step3_sweep")

            onboarding.showStepForTesting(3)
            saveWindow(win, name: "04_onboarding_step4_confirmation")
        }

        // 2. Settings Tabs
        let settings = SettingsWindowController(paths: paths)
        if let win = settings.window {
            win.appearance = appearance
            settings.selectTabForTesting(0)
            saveWindow(win, name: "05_settings_tab1_sync")

            settings.selectTabForTesting(1)
            saveWindow(win, name: "06_settings_tab2_storage")

            settings.selectTabForTesting(2)
            saveWindow(win, name: "07_settings_tab3_raindrop")

            settings.selectTabForTesting(3)
            saveWindow(win, name: "08_settings_tab4_smart_naming")

            settings.selectTabForTesting(4)
            saveWindow(win, name: "09_settings_tab5_advanced")
        }

        // 3. About Window
        let about = AboutWindowController(paths: paths)
        if let win = about.window {
            win.appearance = appearance
            saveWindow(win, name: "10_about_window")
        }

        // 4. Quick Auth Window
        let quickAuth = QuickAuthWindowController(paths: paths)
        if let win = quickAuth.window {
            win.appearance = appearance
            saveWindow(win, name: "11_quick_auth_window")
        }

        // 5. Sweep Progress Window (Running)
        let sweepProgressRunning = SweepProgressWindowController(paths: paths)
        if let win = sweepProgressRunning.window {
            win.appearance = appearance

            let runningStatus = SweepStatus(
                state: .running,
                phase: .organizing,
                total: 184,
                completed: 72,
                uploaded: 68,
                skipped: 4,
                failed: 0,
                remaining: 112
            )
            sweepProgressRunning.updateUIForTesting(with: runningStatus)
            saveWindow(win, name: "12_sweep_progress_running")
        }

        // 6. Sweep Progress Window (Completed)
        let sweepProgressCompleted = SweepProgressWindowController(paths: paths)
        if let win = sweepProgressCompleted.window {
            win.appearance = appearance

            let completedStatus = SweepStatus(
                state: .completed,
                phase: .complete,
                total: 184,
                completed: 184,
                uploaded: 180,
                skipped: 4,
                failed: 0,
                remaining: 0
            )
            sweepProgressCompleted.updateUIForTesting(with: completedStatus)
            saveWindow(win, name: "13_sweep_progress_completed")
        }

        // 7. Menu Bar Dropdown Preview
        let statusController = StatusItemController(paths: paths)
        let previewMenu = NSMenu()
        statusController.menuNeedsUpdate(previewMenu)
        let menuWindow = createMenuPreviewWindow(menu: previewMenu, appearance: appearance)
        saveWindow(menuWindow, name: "14_menu_dropdown")
    }

    private final class FlippedVisualEffectView: NSVisualEffectView {
        override var isFlipped: Bool { true }
    }

    private static func createMenuPreviewWindow(menu: NSMenu, appearance: NSAppearance?) -> NSWindow {
        let width: CGFloat = 260
        var totalHeight: CGFloat = 16

        for item in menu.items where !item.isAlternate {
            if let v = item.view {
                totalHeight += v.frame.height + 4
            } else if item.isSeparatorItem {
                totalHeight += 11
            } else {
                totalHeight += 26
            }
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: totalHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear

        let visualEffect = FlippedVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10.0
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        var currentY: CGFloat = 6

        for item in menu.items where !item.isAlternate {
            if let customView = item.view {
                customView.frame = NSRect(x: 0, y: currentY, width: width, height: customView.frame.height)
                visualEffect.addSubview(customView)
                currentY += customView.frame.height + 4
            } else if item.isSeparatorItem {
                currentY += 4
                let sep = NSBox(frame: NSRect(x: 12, y: currentY, width: width - 24, height: 1))
                sep.boxType = .separator
                visualEffect.addSubview(sep)
                currentY += 6
            } else {
                if let img = item.image {
                    let iv = NSImageView(frame: NSRect(x: 14, y: currentY + 4, width: 16, height: 16))
                    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                    iv.image = img.withSymbolConfiguration(cfg)
                    iv.contentTintColor = .secondaryLabelColor
                    visualEffect.addSubview(iv)
                }

                let textX: CGFloat = (item.image != nil) ? 36 : 14
                let label = NSTextField(labelWithString: item.title)
                label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
                label.textColor = item.isEnabled ? .labelColor : .disabledControlTextColor
                label.frame = NSRect(x: textX, y: currentY + 3, width: width - textX - 44, height: 18)
                visualEffect.addSubview(label)

                if item.hasSubmenu {
                    let chev = NSImageView(frame: NSRect(x: width - 22, y: currentY + 6, width: 10, height: 12))
                    let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                    if let img = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                        chev.image = img
                        chev.contentTintColor = .tertiaryLabelColor
                    }
                    visualEffect.addSubview(chev)
                } else if !item.keyEquivalent.isEmpty {
                    let shortcut = NSTextField(labelWithString: "⌘\(item.keyEquivalent.uppercased())")
                    shortcut.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                    shortcut.textColor = .secondaryLabelColor
                    shortcut.alignment = .right
                    shortcut.frame = NSRect(x: width - 48, y: currentY + 3, width: 34, height: 18)
                    visualEffect.addSubview(shortcut)
                }

                currentY += 26
            }
        }

        win.contentView = visualEffect
        return win
    }
}
