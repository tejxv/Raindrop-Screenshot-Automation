import XCTest
import Foundation
@testable import RaindropShotCore

final class OAuthTests: XCTestCase {
    func testBuildAuthorizeURL() {
        let oauth = OAuthHelper()
        guard let url = oauth.buildAuthorizeURL() else {
            XCTFail("Failed to build authorize URL")
            return
        }

        XCTAssertTrue(url.absoluteString.contains("raindrop.io/oauth/authorize"))
        XCTAssertTrue(url.absoluteString.contains("client_id=68789ff689798d7d715b1143"))
        XCTAssertTrue(url.absoluteString.contains("redirect_uri=http%3A%2F%2Flocalhost%3A7890%2Fcallback") || url.absoluteString.contains("http://localhost:7890/callback"))
        XCTAssertTrue(url.absoluteString.contains("response_type=code"))
    }

    func testOAuthLoopbackServerReceivesCode() async throws {
        let testPort: UInt16 = 7891
        let server = OAuthLoopbackServer(port: testPort)

        let task = Task {
            try await server.waitForCode(timeout: 5)
        }

        // Wait brief moment for socket to bind and listen
        try await Task.sleep(nanoseconds: 200_000_000)

        // Make simulated HTTP request
        let url = URL(string: "http://127.0.0.1:\(testPort)/callback?code=TEST_OAUTH_CODE_12345")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200)

        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Connected to Raindrop"))

        let receivedCode = try await task.value
        XCTAssertEqual(receivedCode, "TEST_OAUTH_CODE_12345")
    }

    func testOAuthLoopbackServerCancellation() async throws {
        let testPort: UInt16 = 7892
        let server = OAuthLoopbackServer(port: testPort)

        let task = Task {
            try await server.waitForCode(timeout: 10)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        server.cancel()

        do {
            _ = try await task.value
            XCTFail("Should have thrown cancellation or connection error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cancelled") || error.localizedDescription.contains("timed out") || error.localizedDescription.contains("failed"))
        }
    }
}
