import Foundation

/// Reads the system screenshot preferences (`com.apple.screencapture`) without
/// spawning `defaults`. Read-only; we never write the user's screencapture domain.
public enum ScreenshotLocation {
    private static var domain: UserDefaults? { UserDefaults(suiteName: "com.apple.screencapture") }

    /// The folder macOS currently saves screenshots to, if one is configured and exists.
    public static func systemFolder() -> URL? {
        guard let raw = domain?.string(forKey: "location"), !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// System folder if configured, otherwise `~/Desktop` (the macOS default).
    public static func defaultFolder() -> URL {
        systemFolder() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Custom file name prefix set with `defaults write com.apple.screencapture name …`.
    public static func customNamePrefix() -> String? {
        guard let name = domain?.string(forKey: "name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    /// `true` when screenshots go to the clipboard instead of a file (nothing for us to upload).
    public static var savesToClipboard: Bool {
        domain?.string(forKey: "target") == "clipboard"
    }
}
