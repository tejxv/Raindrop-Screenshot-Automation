import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Defines the contract for on-device screenshot metadata generation.
public protocol ScreenshotNamingType: Sendable {
    /// Returns whether the on-device model is currently available and ready for inference, or an explanatory reason if not.
    func isAvailable() -> (available: Bool, reason: String?)

    /// Generates structured metadata for the screenshot at the given file URL.
    /// Throws if inference fails, is unsupported, or times out.
    func generateMetadata(for fileURL: URL) async throws -> ScreenshotMetadata

    /// Cleans up any cached language model session at the end of a worker batch run.
    func finishBatch() async
}

// MARK: - Internal Generable Type

#if canImport(FoundationModels)
@available(macOS 27.0, *)
@Generable
struct InternalGenerableMetadata: Sendable {
    @Guide(description: "concise filesystem-safe name using roughly 3 to 6 meaningful words, lowercase, hyphen-separated, no extension")
    var filename: String

    @Guide(description: "short human-readable title for the screenshot")
    var title: String

    @Guide(description: "one concise sentence describing the useful content visible in the screenshot")
    var description: String
}

@available(macOS 27.0, *)
private actor SessionHolder {
    private var session: LanguageModelSession?

    func getOrCreateSession() -> LanguageModelSession {
        if let session {
            return session
        }

        let instructions = """
        Analyze this screenshot and generate metadata that helps the user find it later.
        Use text visibly present in the screenshot as the strongest signal.
        Identify recognizable applications, websites, documents, projects, code, settings pages, dashboards or other visible context when confidence is high.
        Do not speculate about information that is not visible.

        filename:
        - 3 to 6 meaningful words
        - lowercase, hyphen-separated, no file extension
        - no generic words like screenshot, image, window, screen, picture

        title:
        - natural human-readable title

        description:
        - one short factual sentence describing the useful content.
        """

        let newSession = LanguageModelSession(model: .default, instructions: instructions)
        self.session = newSession
        return newSession
    }

    func release() {
        self.session = nil
    }
}
#endif

// MARK: - Apple Foundation Models Implementation

public final class AppleFoundationModelsNamingService: ScreenshotNamingType, @unchecked Sendable {
    #if canImport(FoundationModels)
    private var sessionHolderStorage: Any?
    #endif

    public init() {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            self.sessionHolderStorage = SessionHolder()
        }
        #endif
    }

    public func isAvailable() -> (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                return (true, nil)
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return (false, "Device unsupported")
                case .appleIntelligenceNotEnabled:
                    return (false, "Apple Intelligence disabled in System Settings")
                case .modelNotReady:
                    return (false, "Model downloading or not ready")
                @unknown default:
                    return (false, "Apple Intelligence unavailable")
                }
            }
        } else {
            return (false, "macOS version unsupported")
        }
        #else
        return (false, "FoundationModels framework unavailable")
        #endif
    }

    public func generateMetadata(for fileURL: URL) async throws -> ScreenshotMetadata {
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *) else {
            throw CocoaError(.featureUnsupported)
        }

        let status = isAvailable()
        guard status.available else {
            throw NSError(
                domain: "RaindropShot.SmartNaming",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: status.reason ?? "Apple Intelligence unavailable"]
            )
        }

        guard let holder = sessionHolderStorage as? SessionHolder else {
            throw CocoaError(.featureUnsupported)
        }

        let session = await holder.getOrCreateSession()

        // Extract visible OCR text to enrich multimodal context
        let ocrText = VisionOCRHelper.extractText(from: fileURL)

        let prompt = Prompt {
            Attachment(imageURL: fileURL)
            if let ocrText, !ocrText.isEmpty {
                "Visible text detected in screenshot:\n\(ocrText)"
            }
            "Generate structured metadata for this screenshot."
        }

        let response = try await session.respond(to: prompt, generating: InternalGenerableMetadata.self)
        let fallbackBase = fileURL.deletingPathExtension().lastPathComponent

        let rawFilename = response.content.filename
        let sanitizedName = FilenameSanitizer.sanitizeBaseName(rawName: rawFilename, fallback: fallbackBase)

        let cleanTitle = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? fallbackBase : cleanTitle

        let cleanDesc = response.content.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDesc = cleanDesc.isEmpty ? "Captured screenshot" : cleanDesc

        return ScreenshotMetadata(
            filename: sanitizedName,
            title: finalTitle,
            description: finalDesc
        )
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    public func finishBatch() async {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            if let holder = sessionHolderStorage as? SessionHolder {
                await holder.release()
            }
        }
        #endif
    }
}

// MARK: - Mock Implementation for Testing

public final class MockScreenshotNamingService: ScreenshotNamingType, @unchecked Sendable {
    public var isAvailableResult: (available: Bool, reason: String?)
    public var metadataResult: Result<ScreenshotMetadata, Error>
    public private(set) var invokedURLs: [URL] = []
    public private(set) var batchFinished: Bool = false

    public init(
        isAvailableResult: (available: Bool, reason: String?) = (true, nil),
        metadataResult: Result<ScreenshotMetadata, Error> = .success(
            ScreenshotMetadata(
                filename: "borrowbox-rental-dashboard",
                title: "BorrowBox Rental Dashboard",
                description: "Dashboard showing generator rental requests and status."
            )
        )
    ) {
        self.isAvailableResult = isAvailableResult
        self.metadataResult = metadataResult
    }

    public func isAvailable() -> (available: Bool, reason: String?) {
        isAvailableResult
    }

    public func generateMetadata(for fileURL: URL) async throws -> ScreenshotMetadata {
        invokedURLs.append(fileURL)
        switch metadataResult {
        case .success(let metadata):
            return metadata
        case .failure(let error):
            throw error
        }
    }

    public func finishBatch() async {
        batchFinished = true
    }
}
