import AppKit

/// A refined, compact macOS status header view for the menu bar dropdown.
/// Displays an active status dot, high-contrast title, secondary timestamp,
/// and an integrated action pill button (e.g. "Sync Now").
@MainActor
public final class StatusHeaderView: NSView {
    public struct Config {
        public let title: String
        public let subtitle: String
        public let dotColor: NSColor
        public let buttonTitle: String
        public let buttonColor: NSColor
        public let buttonAction: (() -> Void)?

        public init(
            title: String,
            subtitle: String,
            dotColor: NSColor = .systemGreen,
            buttonTitle: String = "Sync Now",
            buttonColor: NSColor = .controlAccentColor,
            buttonAction: (() -> Void)? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.dotColor = dotColor
            self.buttonTitle = buttonTitle
            self.buttonColor = buttonColor
            self.buttonAction = buttonAction
        }
    }

    private let config: Config
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var isPressed = false {
        didSet { if oldValue != isPressed { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    public init(config: Config, width: CGFloat = 260, height: CGFloat = 50) {
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(config.title), \(config.subtitle)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var buttonRect: NSRect {
        guard !config.buttonTitle.isEmpty, config.buttonAction != nil else { return .zero }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let textWidth = (config.buttonTitle as NSString).size(withAttributes: [.font: font]).width
        let btnWidth = max(66, textWidth + 18)
        let btnHeight: CGFloat = 24
        let btnX = bounds.width - btnWidth - 14
        let btnY = (bounds.height - btnHeight) / 2
        return NSRect(x: btnX, y: btnY, width: btnWidth, height: btnHeight)
    }

    public override var isFlipped: Bool { true }

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
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if mouseInButton && config.buttonAction != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        isHovered = mouseInButton
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    public override func mouseMoved(with event: NSEvent) {
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if isHovered != mouseInButton {
            isHovered = mouseInButton
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if mouseInButton && config.buttonAction != nil {
            isPressed = true
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        needsDisplay = true

        let mouseInButton = buttonRect.contains(convert(event.locationInWindow, from: nil))
        if mouseInButton, let action = config.buttonAction {
            enclosingMenuItem?.menu?.cancelTracking()
            action()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let btnR = buttonRect
        let hasButton = !btnR.isEmpty

        // 1. Status Dot
        let dotSize: CGFloat = 8.0
        let dotX: CGFloat = 14.0
        let dotY: CGFloat = 14.0
        let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        config.dotColor.setFill()
        dotPath.fill()

        // 2. Title Text
        let textX: CGFloat = dotRect.maxX + 8.0
        let maxTextWidth = hasButton ? (btnR.minX - textX - 8) : (bounds.width - textX - 14)

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor
        ]
        let titleStr = NSAttributedString(string: config.title, attributes: titleAttrs)
        let titleRect = NSRect(x: textX, y: 9, width: maxTextWidth, height: 18)
        titleStr.draw(in: titleRect)

        // 3. Subtitle Text
        let subFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let subStr = NSAttributedString(string: config.subtitle, attributes: subAttrs)
        let subRect = NSRect(x: textX, y: 27, width: maxTextWidth, height: 16)
        subStr.draw(in: subRect)

        // 4. Action Button (Pill)
        if hasButton {
            let cornerRadius: CGFloat = 6.0
            let path = NSBezierPath(roundedRect: btnR, xRadius: cornerRadius, yRadius: cornerRadius)

            let baseColor = config.buttonColor
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

            let borderColor = baseColor.withAlphaComponent(isHovered ? 0.48 : 0.28)
            borderColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let btnFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            let btnTextColor = isPressed ? baseColor : NSColor.labelColor
            let btnAttrs: [NSAttributedString.Key: Any] = [
                .font: btnFont,
                .foregroundColor: btnTextColor
            ]
            let btnTitleStr = NSAttributedString(string: config.buttonTitle, attributes: btnAttrs)
            let strSize = btnTitleStr.size()
            let strX = btnR.midX - (strSize.width / 2.0)
            let strY = btnR.midY - (strSize.height / 2.0)
            btnTitleStr.draw(at: NSPoint(x: strX, y: strY))
        }
    }
}
