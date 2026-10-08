import Foundation
#if canImport(Vision)
import Vision
#endif

public enum VisionOCRHelper {
    /// Extracts prominent text lines from a screenshot using Vision OCR in fast recognition mode.
    /// Returns `nil` if text recognition fails or finds no readable content.
    public static func extractText(from imageURL: URL, maxLines: Int = 30) -> String? {
        #if canImport(Vision)
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results, !results.isEmpty else { return nil }
            let lines = results.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            return lines.prefix(maxLines).joined(separator: "\n")
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
