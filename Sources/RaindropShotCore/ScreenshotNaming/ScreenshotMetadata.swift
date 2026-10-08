import Foundation

/// Structured metadata generated for a screenshot.
public struct ScreenshotMetadata: Codable, Sendable, Equatable {
    /// Concise filesystem-safe name using 3 to 6 meaningful words, lowercase, hyphen-separated, no file extension.
    public var filename: String

    /// Short human-readable title for the screenshot.
    public var title: String

    /// One concise sentence describing the useful content visible in the screenshot.
    public var description: String

    public init(filename: String, title: String, description: String) {
        self.filename = filename
        self.title = title
        self.description = description
    }
}
