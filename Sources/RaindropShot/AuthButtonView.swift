import AppKit

/// A sleek, minimal button view hosted inside an NSMenuItem.
/// Matches macOS Human Interface Guidelines with rounded rect styling, subtle accent tints,
/// hover state transitions, and pointing hand cursor feedback.
@MainActor
public final class AuthButtonView: NSView {
    private let title: String
    private let iconName: String
    private let action: () -> Void

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if oldValue != isPressed { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    public init(
        title: String = "Sign In to Raindrop",
        iconName: String = "key.fill",
        width: CGFloat = 236,
        height: CGFloat = 38,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.iconName = iconName
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func cursorUpdate(with event: NSEvent) {
        let buttonRect = bounds.insetBy(dx: 10, dy: 4)
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if mouseInButton {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    public override func mouseDown(with event: NSEvent) {
        let buttonRect = bounds.insetBy(dx: 10, dy: 4)
        if buttonRect.contains(convert(event.locationInWindow, from: nil)) {
            isPressed = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false

        let buttonRect = bounds.insetBy(dx: 10, dy: 4)
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if mouseInButton {
            // Dismiss active menu
            enclosingMenuItem?.menu?.cancelTracking()
            // Dispatch action
            action()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let buttonRect = bounds.insetBy(dx: 10, dy: 4)
        let cornerRadius: CGFloat = 6.0
        let path = NSBezierPath(roundedRect: buttonRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Background Tint
        let baseColor = NSColor.controlAccentColor
        let fillColor: NSColor
        if isPressed {
            fillColor = baseColor.withAlphaComponent(0.32)
        } else if isHovered {
            fillColor = baseColor.withAlphaComponent(0.20)
        } else {
            fillColor = baseColor.withAlphaComponent(0.12)
        }

        fillColor.setFill()
        path.fill()

        // Border Stroke
        let borderColor = baseColor.withAlphaComponent(isHovered ? 0.48 : 0.28)
        borderColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        // Icon
        let iconSize: CGFloat = 13.0
        let iconX = buttonRect.minX + 11.0
        let iconY = buttonRect.midY - (iconSize / 2.0)
        let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [baseColor]))
        if let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
            symbolImage.draw(in: iconRect)
        }

        // Title text
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let textColor = isPressed ? baseColor : NSColor.labelColor
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        let titleString = NSAttributedString(string: title, attributes: textAttributes)
        let titleSize = titleString.size()
        let titleX = iconRect.maxX + 8.0
        let titleY = buttonRect.midY - (titleSize.height / 2.0)
        titleString.draw(at: NSPoint(x: titleX, y: titleY))

        // Trailing Chevron
        let chevronSize: CGFloat = 10.0
        let chevronX = buttonRect.maxX - chevronSize - 11.0
        let chevronY = buttonRect.midY - (chevronSize / 2.0)
        let chevronRect = NSRect(x: chevronX, y: chevronY, width: chevronSize, height: chevronSize)

        let chevConfig = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [baseColor.withAlphaComponent(0.85)]))
        if let chevImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(chevConfig) {
            chevImage.draw(in: chevronRect)
        }
    }
}
