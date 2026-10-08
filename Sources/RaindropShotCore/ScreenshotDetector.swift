import Foundation
import Darwin

public struct ScreenshotDetector: Sendable {
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "tiff"
    ]

    /// Known localized prefixes used by macOS screencapture across various languages.
    public static let localizedPrefixes: [String] = [
        "Screenshot",
        "Screen Shot",
        "Capture d’écran",
        "Capture d'écran",
        "Bildschirmfoto",
        "Captura de pantalla",
        "Captura de tela",
        "Captura de ecrã",
        "Istantanea",
        "Schermafbeelding",
        "Снимок экрана",
        "Skjermbilde",
        "Skærmbillede",
        "Skärmavbild",
        "Näyttökuva",
        "Zrzut ekranu",
        "Kuvakaappaus",
        "Snimak zaslona",
        "Snimka zaslona",
        "Képernyőfotó",
        "Скриншот",
        "화면 캡처",
        "スクリーンショット",
        "屏幕快照",
        "螢幕快照"
    ]

    public init() {}

    /// Checks if a file at the given URL looks like a screenshot.
    /// Uses multiple signals:
    /// 1. Extended attribute `com.apple.metadata:kMDItemIsScreenCapture`
    /// 2. Configured custom screencapture prefix from `com.apple.screencapture`
    /// 3. Standard macOS multilingual screenshot prefixes
    /// 4. If mode is `.allImages`, any image with supported extension is accepted.
    public func isScreenshot(url: URL, mode: DetectionMode = .screenshotsOnly) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            return false
        }

        if mode == .allImages {
            return true
        }

        // Signal 1: Extended attribute set by macOS screencapture
        if hasScreenCaptureXattr(at: url) {
            return true
        }

        let filename = url.lastPathComponent

        // Signal 2: Custom prefix configured in macOS screencapture settings
        if let customPrefix = ScreenshotLocation.customNamePrefix(), !customPrefix.isEmpty {
            if filename.hasPrefix(customPrefix) {
                return true
            }
        }

        // Signal 3: Localized standard prefixes
        for prefix in Self.localizedPrefixes {
            if filename.hasPrefix(prefix) {
                return true
            }
        }

        // Signal 4: Common third-party tool prefixes (CleanShot, Shottr, Kap)
        let toolPrefixes = ["CleanShot", "Shottr", "Kap "]
        for prefix in toolPrefixes {
            if filename.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    /// Checks for the `com.apple.metadata:kMDItemIsScreenCapture` extended attribute.
    public func hasScreenCaptureXattr(at url: URL) -> Bool {
        let path = url.path
        let attrName = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(path, attrName, nil, 0, 0, 0)
        return size > 0
    }

    /// Checks if the file has finished being written.
    /// If the file was modified less than `minimumAge` seconds ago or is currently 0 bytes,
    /// it is considered unstable and should be skipped until the next run.
    public func isFileStable(url: URL, now: Date = Date(), minimumAge: TimeInterval = 2.0) -> Bool {
        var statBuf = stat()
        guard stat(url.path, &statBuf) == 0 else {
            return false
        }

        // 0-byte file is definitely not ready
        guard statBuf.st_size > 0 else {
            return false
        }

        // Check modification time
        let modSec = TimeInterval(statBuf.st_mtimespec.tv_sec) + TimeInterval(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000.0
        let age = now.timeIntervalSince1970 - modSec

        if age < minimumAge {
            return false
        }

        // Try opening read-only to verify no exclusive write lock
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return true
        } else {
            return false
        }
    }
}
