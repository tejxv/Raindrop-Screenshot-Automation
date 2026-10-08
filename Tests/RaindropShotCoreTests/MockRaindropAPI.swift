import Foundation
import RaindropShotCore

public final class MockRaindropAPI: RaindropAPIType, @unchecked Sendable {
    public var uploadResult: Result<UploadResponse.UploadItem, RaindropAPIError>
    public var updateResult: Result<Void, RaindropAPIError>
    public var collectionsResult: Result<[RaindropCollectionItem], RaindropAPIError>
    public var userQuotaResult: Result<UserQuota?, RaindropAPIError>
    public var testConnectionResult: Result<Bool, RaindropAPIError>

    public private(set) var uploadedFiles: [URL] = []
    public private(set) var uploadedTokens: [String] = []
    public private(set) var uploadedCollectionIds: [Int?] = []
    public private(set) var updatedMetadata: [(id: Int, title: String?, tags: [String]?, excerpt: String?)] = []

    public init(
        uploadResult: Result<UploadResponse.UploadItem, RaindropAPIError> = .success(
            UploadResponse.UploadItem(_id: 12345, link: "https://raindrop.io/test.png", title: "Test", collectionId: nil)
        ),
        updateResult: Result<Void, RaindropAPIError> = .success(()),
        collectionsResult: Result<[RaindropCollectionItem], RaindropAPIError> = .success([]),
        userQuotaResult: Result<UserQuota?, RaindropAPIError> = .success(nil),
        testConnectionResult: Result<Bool, RaindropAPIError> = .success(true)
    ) {
        self.uploadResult = uploadResult
        self.updateResult = updateResult
        self.collectionsResult = collectionsResult
        self.userQuotaResult = userQuotaResult
        self.testConnectionResult = testConnectionResult
    }

    public func uploadFile(fileURL: URL, token: String, collectionId: Int?) async throws -> UploadResponse.UploadItem {
        uploadedFiles.append(fileURL)
        uploadedTokens.append(token)
        uploadedCollectionIds.append(collectionId)

        switch uploadResult {
        case .success(let item):
            return item
        case .failure(let error):
            throw error
        }
    }

    public func updateRaindropMetadata(id: Int, token: String, title: String?, tags: [String]?, excerpt: String?) async throws {
        updatedMetadata.append((id: id, title: title, tags: tags, excerpt: excerpt))
        switch updateResult {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    public func getCollections(token: String) async throws -> [RaindropCollectionItem] {
        switch collectionsResult {
        case .success(let items):
            return items
        case .failure(let error):
            throw error
        }
    }

    public func getUserQuota(token: String) async throws -> UserQuota? {
        switch userQuotaResult {
        case .success(let quota):
            return quota
        case .failure(let error):
            throw error
        }
    }

    public func testConnection(token: String) async throws -> Bool {
        switch testConnectionResult {
        case .success(let ok):
            return ok
        case .failure(let error):
            throw error
        }
    }
}
