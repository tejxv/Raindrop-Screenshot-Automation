import Foundation

public enum FilenameSanitizer {
    public static let genericStopWords: Set<String> = [
        "screenshot", "screen", "shot", "image", "img", "window", "picture", "photo", "pic", "capture"
    ]

    public static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "with", "by", "from", "is", "it"
    ]

    /// Sanitizes raw model output or file names to ensure strict adherence to naming rules:
    /// - 3 to 6 meaningful words
    /// - lowercase, hyphen-separated
    /// - no extension
    /// - no generic words like screenshot/image/window/screen
    /// - no timestamps
    /// - no punctuation other than hyphens
    public static func sanitizeBaseName(rawName: String, fallback: String) -> String {
        // 1. Strip any extension
        var name = (rawName as NSString).deletingPathExtension
        if name.isEmpty { name = rawName }

        // 2. Lowercase
        name = name.lowercased()

        // 3. Strip timestamp patterns like "2026-10-08" or "1.03.42 pm"
        let timestampPattern = #"\b\d{4}[-_]\d{2}[-_]\d{2}\b|\b\d{1,2}[-.:]\d{2}([-.:]\d{2})?(\s*(am|pm))?\b"#
        if let timestampRegex = try? NSRegularExpression(pattern: timestampPattern, options: .caseInsensitive) {
            name = timestampRegex.stringByReplacingMatches(in: name, options: [], range: NSRange(location: 0, length: name.utf16.count), withTemplate: " ")
        }

        // 4. Replace any non-alphanumeric character with a hyphen
        let allowed = CharacterSet.alphanumerics
        var chars: [Character] = []
        for scalar in name.unicodeScalars {
            if allowed.contains(scalar) {
                chars.append(Character(scalar))
            } else {
                chars.append("-")
            }
        }
        let hyphenated = String(chars)

        // 5. Split by hyphen into words
        let rawWords = hyphenated.split(separator: "-").map(String.init)

        // 6. Filter out all generic stop words and filler words
        let meaningless = genericStopWords.union(fillerWords)
        let candidateWords = rawWords.filter { !meaningless.contains($0) }

        // 7. Deduplicate adjacent identical words
        var deduplicated: [String] = []
        for word in candidateWords {
            if deduplicated.last != word {
                deduplicated.append(word)
            }
        }

        // 8. Limit to at most 6 words
        if deduplicated.count > 6 {
            deduplicated = Array(deduplicated.prefix(6))
        }

        // 9. If empty, fall back to sanitized fallback
        if deduplicated.isEmpty {
            let fallbackBase = (fallback as NSString).deletingPathExtension
            var fbChars: [Character] = []
            for scalar in fallbackBase.lowercased().unicodeScalars {
                if allowed.contains(scalar) {
                    fbChars.append(Character(scalar))
                } else {
                    fbChars.append("-")
                }
            }
            let fbWords = String(fbChars).split(separator: "-").map(String.init)
            let filteredFb = fbWords.filter { !genericStopWords.contains($0) }
            if !filteredFb.isEmpty {
                return filteredFb.prefix(6).joined(separator: "-")
            } else if !fbWords.isEmpty {
                return fbWords.prefix(6).joined(separator: "-")
            }
            return "screenshot"
        }

        return deduplicated.joined(separator: "-")
    }

    /// Resolves a safe destination URL, preventing overwriting existing files:
    /// e.g. `borrowbox-dashboard.png` -> `borrowbox-dashboard-2.png` -> `borrowbox-dashboard-3.png`.
    public static func resolveSafeDestinationURL(
        in directory: URL,
        desiredBaseName: String,
        extension ext: String,
        currentIdentity: FileIdentity? = nil
    ) -> URL {
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let extSuffix = cleanExt.isEmpty ? "" : ".\(cleanExt)"

        let primaryURL = directory.appendingPathComponent("\(desiredBaseName)\(extSuffix)")

        // If file doesn't exist, it is safe to use
        if !FileManager.default.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }

        // If it exists, check if it's already the exact same file (same inode/device)
        if let currentIdentity, let existingMeta = FileOperations.metadata(for: primaryURL), existingMeta.identity == currentIdentity {
            return primaryURL
        }

        // Collision: search for -2, -3, ...
        for counter in 2...9999 {
            let candidateURL = directory.appendingPathComponent("\(desiredBaseName)-\(counter)\(extSuffix)")
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            if let currentIdentity, let existingMeta = FileOperations.metadata(for: candidateURL), existingMeta.identity == currentIdentity {
                return candidateURL
            }
        }

        return directory.appendingPathComponent("\(desiredBaseName)-\(UUID().uuidString.prefix(6))\(extSuffix)")
    }

    /// Safely renames a file on disk. Never overwrites an existing file.
    public static func safeRenameFile(from sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.path != destinationURL.path else { return }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
}
