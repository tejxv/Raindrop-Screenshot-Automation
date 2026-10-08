import Foundation

public struct UploadResponse: Codable, Sendable {
    public let result: Bool
    public let item: UploadItem?
    public let error: String?
    public let errorMessage: String?

    public struct UploadItem: Codable, Sendable {
        public let _id: Int
        public let link: String?
        public let title: String?
        public let collectionId: Int?
        public let cover: String?

        public init(_id: Int, link: String? = nil, title: String? = nil, collectionId: Int? = nil, cover: String? = nil) {
            self._id = _id
            self.link = link
            self.title = title
            self.collectionId = collectionId
            self.cover = cover
        }

        enum CodingKeys: String, CodingKey {
            case _id
            case link
            case title
            case collectionId
            case cover
        }
    }
}

public struct RaindropCollectionItem: Codable, Identifiable, Sendable {
    public let _id: Int
    public let title: String
    public let count: Int?

    public var id: Int { _id }
}

public struct RaindropCollectionsResponse: Codable, Sendable {
    public let result: Bool
    public let items: [RaindropCollectionItem]
}

public struct UserQuota: Codable, Sendable {
    public let usedBytes: Int64
    public let totalBytes: Int64
    public let isPro: Bool

    public var usedMB: Double { Double(usedBytes) / (1024 * 1024) }
    public var totalMB: Double { Double(totalBytes) / (1024 * 1024) }
    public var remainingMB: Double { max(0, totalMB - usedMB) }
    public var usedPercent: Int {
        totalBytes > 0 ? Int((Double(usedBytes) / Double(totalBytes)) * 100) : 0
    }
}

public enum RaindropAPIError: LocalizedError, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int)
    case rejected(message: String)
    case offline(message: String)
    case invalidResponse(message: String)
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Raindrop authentication failed or token expired (401)"
        case .rateLimited(let delay):
            return "Rate limited (429). Retry after: \(delay ?? 60)s"
        case .serverError(let code):
            return "Raindrop server error (\(code))"
        case .rejected(let msg):
            return "File rejected by Raindrop: \(msg)"
        case .offline(let msg):
            return "Network offline or unreachable: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid API response: \(msg)"
        case .missingToken:
            return "No Raindrop access token configured"
        }
    }
}

public protocol RaindropAPIType: Sendable {
    func uploadFile(fileURL: URL, token: String, collectionId: Int?) async throws -> UploadResponse.UploadItem
    func updateRaindropMetadata(id: Int, token: String, title: String?, tags: [String]?, excerpt: String?) async throws
    func getCollections(token: String) async throws -> [RaindropCollectionItem]
    func getUserQuota(token: String) async throws -> UserQuota?
    func testConnection(token: String) async throws -> Bool
}

public final class RaindropAPI: RaindropAPIType, @unchecked Sendable {
    private let baseURL = URL(string: "https://api.raindrop.io/rest/v1")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func uploadFile(fileURL: URL, token: String, collectionId: Int?) async throws -> UploadResponse.UploadItem {
        guard !token.isEmpty else { throw RaindropAPIError.missingToken }

        let boundary = "Boundary-\(UUID().uuidString)"
        let tempBodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("raindrop-upload-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempBodyURL) }

        // Construct multipart body directly onto disk to avoid buffering in RAM
        try createMultipartBodyFile(sourceFile: fileURL, destination: tempBodyURL, boundary: boundary, collectionId: collectionId)

        var request = URLRequest(url: baseURL.appendingPathComponent("raindrop/file"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: tempBodyURL)
        } catch let err as URLError {
            throw RaindropAPIError.offline(message: err.localizedDescription)
        } catch {
            throw RaindropAPIError.offline(message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RaindropAPIError.invalidResponse(message: "Not an HTTP response")
        }

        return try handleUploadHTTPResponse(httpResponse: httpResponse, data: data)
    }

    public func updateRaindropMetadata(id: Int, token: String, title: String?, tags: [String]?, excerpt: String?) async throws {
        guard !token.isEmpty else { throw RaindropAPIError.missingToken }

        let updateURL = baseURL.appendingPathComponent("raindrop/\(id)")
        var request = URLRequest(url: updateURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var bodyObj: [String: Any] = [:]
        if let title = title { bodyObj["title"] = title }
        if let tags = tags, !tags.isEmpty { bodyObj["tags"] = tags }
        if let excerpt = excerpt { bodyObj["excerpt"] = excerpt }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch let err as URLError {
            throw RaindropAPIError.offline(message: err.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else { return }
        if httpResponse.statusCode == 401 { throw RaindropAPIError.unauthorized }
        if httpResponse.statusCode == 429 { throw RaindropAPIError.rateLimited(retryAfter: 60) }
    }

    public func getCollections(token: String) async throws -> [RaindropCollectionItem] {
        guard !token.isEmpty else { throw RaindropAPIError.missingToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("collections"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RaindropAPIError.invalidResponse(message: "Not HTTP")
        }
        if httpResponse.statusCode == 401 { throw RaindropAPIError.unauthorized }

        let decoded = try JSONDecoder().decode(RaindropCollectionsResponse.self, from: data)
        return decoded.items
    }

    public func getUserQuota(token: String) async throws -> UserQuota? {
        guard !token.isEmpty else { throw RaindropAPIError.missingToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("user"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        // Parse user quota from JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any] else {
            return nil
        }

        let isPro = user["pro"] as? Bool ?? false
        let files = user["files"] as? [String: Any]
        let used = (files?["used"] as? NSNumber)?.int64Value ?? 0
        let total = (files?["size"] as? NSNumber)?.int64Value ?? (isPro ? 10_000_000_000 : 104_857_600)

        return UserQuota(usedBytes: used, totalBytes: total, isPro: isPro)
    }

    public func testConnection(token: String) async throws -> Bool {
        guard !token.isEmpty else { throw RaindropAPIError.missingToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("user"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        if httpResponse.statusCode == 401 { throw RaindropAPIError.unauthorized }
        return httpResponse.statusCode == 200
    }

    // MARK: - Private Helpers

    private func handleUploadHTTPResponse(httpResponse: HTTPURLResponse, data: Data) throws -> UploadResponse.UploadItem {
        switch httpResponse.statusCode {
        case 200...204:
            let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
            if let item = decoded.item {
                return item
            } else if let errorMsg = decoded.errorMessage ?? decoded.error {
                throw RaindropAPIError.rejected(message: errorMsg)
            } else {
                throw RaindropAPIError.invalidResponse(message: "Missing item in 200 response")
            }

        case 401:
            throw RaindropAPIError.unauthorized

        case 429:
            var retrySec: TimeInterval? = nil
            if let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(retryHeader) {
                retrySec = seconds
            }
            throw RaindropAPIError.rateLimited(retryAfter: retrySec)

        case 400:
            if let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data),
               let msg = decoded.errorMessage ?? decoded.error {
                throw RaindropAPIError.rejected(message: msg)
            }
            let text = String(data: data, encoding: .utf8) ?? "Bad Request"
            throw RaindropAPIError.rejected(message: text)

        case 500...599:
            throw RaindropAPIError.serverError(statusCode: httpResponse.statusCode)

        default:
            let text = String(data: data, encoding: .utf8) ?? "Status code \(httpResponse.statusCode)"
            throw RaindropAPIError.invalidResponse(message: text)
        }
    }

    private func createMultipartBodyFile(
        sourceFile: URL,
        destination: URL,
        boundary: String,
        collectionId: Int?
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { try? outputHandle.close() }

        let lineBreak = "\r\n"

        // 1. collectionId field (if present)
        if let collectionId = collectionId {
            var colPart = "--\(boundary)\(lineBreak)"
            colPart += "Content-Disposition: form-data; name=\"collectionId\"\(lineBreak)\(lineBreak)"
            colPart += "\(collectionId)\(lineBreak)"
            if let colData = colPart.data(using: .utf8) {
                try outputHandle.write(contentsOf: colData)
            }
        }

        // 2. file field header
        let filename = sourceFile.lastPathComponent
        let mimeType = mimeTypeFor(url: sourceFile)
        var filePart = "--\(boundary)\(lineBreak)"
        filePart += "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lineBreak)"
        filePart += "Content-Type: \(mimeType)\(lineBreak)\(lineBreak)"
        if let fileHeaderData = filePart.data(using: .utf8) {
            try outputHandle.write(contentsOf: fileHeaderData)
        }

        // 3. Stream source file contents into destination
        let inputHandle = try FileHandle(forReadingFrom: sourceFile)
        defer { try? inputHandle.close() }

        let bufferSize = 64 * 1024
        while true {
            let chunk = inputHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }
            try outputHandle.write(contentsOf: chunk)
        }

        // 4. Closing boundary
        let closing = "\(lineBreak)--\(boundary)--\(lineBreak)"
        if let closingData = closing.data(using: .utf8) {
            try outputHandle.write(contentsOf: closingData)
        }
    }

    private func mimeTypeFor(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }
}
