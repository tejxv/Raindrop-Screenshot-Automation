import Foundation

public struct OAuthTokenResponse: Codable, Sendable {
    public let access_token: String
    public let refresh_token: String?
    public let expires_in: Int?
    public let token_type: String?
}

public enum OAuthError: LocalizedError, Sendable {
    case invalidURL
    case networkError(String)
    case serverError(statusCode: Int, body: String)
    case invalidResponse(String)
    case exchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OAuth URL"
        case .networkError(let msg):
            return "OAuth network error: \(msg)"
        case .serverError(let code, let body):
            return "OAuth server error (\(code)): \(body)"
        case .invalidResponse(let msg):
            return "Invalid OAuth response: \(msg)"
        case .exchangeFailed(let msg):
            return "Token exchange failed: \(msg)"
        }
    }
}

public struct OAuthHelper: Sendable {
    public static let defaultClientId = "68789ff689798d7d715b1143"
    public static let defaultClientSecret = "643231c3-c93e-40dd-a808-fcf2d680cdaf"
    public static let defaultRedirectURI = "http://localhost:7890/callback"
    public static let tokenEndpoint = URL(string: "https://raindrop.io/oauth/access_token")!

    public init() {}

    /// Builds the authorization URL for the user to visit in their browser.
    public func buildAuthorizeURL(clientId: String = defaultClientId, redirectUri: String = defaultRedirectURI) -> URL? {
        var components = URLComponents(string: "https://raindrop.io/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code")
        ]
        return components?.url
    }

    /// Exchanges an authorization code for an access token.
    public func exchangeCode(
        code: String,
        clientId: String,
        clientSecret: String,
        redirectUri: String = defaultRedirectURI
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_secret": clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            "redirect_uri": redirectUri
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse("Not HTTP")
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.serverError(statusCode: http.statusCode, body: bodyText)
        }

        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.exchangeFailed("Could not parse response: \(bodyText)")
        }
    }

    /// Refreshes an expired access token using a refresh token.
    public func refreshToken(
        refreshToken: String,
        clientId: String,
        clientSecret: String
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_secret": clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500, body: bodyText)
        }

        return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    }

    /// Runs the complete browser-based OAuth flow:
    /// starts loopback listener, invokes onAuthorizeURLReady callback (to open browser),
    /// catches redirected code, and exchanges it for an access token.
    public func performOAuthFlow(
        clientId: String = defaultClientId,
        clientSecret: String = defaultClientSecret,
        redirectUri: String = defaultRedirectURI,
        server: OAuthLoopbackServer = OAuthLoopbackServer(port: 7890),
        onAuthorizeURLReady: (@Sendable (URL) -> Void)? = nil
    ) async throws -> String {
        guard let url = buildAuthorizeURL(clientId: clientId, redirectUri: redirectUri) else {
            throw OAuthError.invalidURL
        }

        onAuthorizeURLReady?(url)

        let code = try await server.waitForCode()
        let resp = try await exchangeCode(
            code: code,
            clientId: clientId,
            clientSecret: clientSecret,
            redirectUri: redirectUri
        )
        return resp.access_token
    }
}

/// Lightweight Darwin socket HTTP server listening on loopback (127.0.0.1:7890).
/// Captures the OAuth authorization code redirected by Raindrop.io and serves a clean confirmation page.
public final class OAuthLoopbackServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isCancelled = false
    public let port: UInt16
    private let lock = NSLock()

    public init(port: UInt16 = 7890) {
        self.port = port
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }

    public func waitForCode(timeout: TimeInterval = 120) async throws -> String {
        cancel()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: OAuthError.networkError("Server deallocated"))
                    return
                }

                let sFd = socket(AF_INET, SOCK_STREAM, 0)
                guard sFd >= 0 else {
                    continuation.resume(throwing: OAuthError.networkError("Failed to create socket"))
                    return
                }

                self.lock.lock()
                self.serverFd = sFd
                self.isCancelled = false
                self.lock.unlock()

                var reuse: Int32 = 1
                setsockopt(sFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(sFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(self.port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")

                let bindRes = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        bind(sFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                guard bindRes == 0 else {
                    close(sFd)
                    continuation.resume(throwing: OAuthError.networkError("Failed to bind port \(self.port) (error \(errno))"))
                    return
                }

                guard listen(sFd, 1) == 0 else {
                    close(sFd)
                    continuation.resume(throwing: OAuthError.networkError("Failed to listen on port \(self.port)"))
                    return
                }

                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFd = accept(sFd, &clientAddr, &clientLen)

                self.lock.lock()
                let wasCancelled = self.isCancelled
                self.lock.unlock()

                if wasCancelled {
                    if clientFd >= 0 { close(clientFd) }
                    close(sFd)
                    continuation.resume(throwing: OAuthError.networkError("Cancelled"))
                    return
                }

                guard clientFd >= 0 else {
                    close(sFd)
                    continuation.resume(throwing: OAuthError.networkError("Connection timed out or failed"))
                    return
                }

                var buf = [UInt8](repeating: 0, count: 4096)
                let bytesRead = read(clientFd, &buf, buf.count)

                guard bytesRead > 0 else {
                    close(clientFd)
                    close(sFd)
                    continuation.resume(throwing: OAuthError.invalidResponse("Empty request"))
                    return
                }

                let reqStr = String(decoding: buf.prefix(bytesRead), as: UTF8.self)
                let firstLine = reqStr.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.components(separatedBy: " ")

                guard parts.count >= 2, let targetPath = parts.dropFirst().first,
                      let components = URLComponents(string: "http://localhost" + targetPath) else {
                    self.sendHTTPResponse(clientFd: clientFd, success: false, message: "Invalid request.")
                    close(clientFd)
                    close(sFd)
                    continuation.resume(throwing: OAuthError.invalidResponse("Malformed request"))
                    return
                }

                if let err = components.queryItems?.first(where: { $0.name == "error" })?.value {
                    self.sendHTTPResponse(clientFd: clientFd, success: false, message: "Authorization declined: \(err)")
                    close(clientFd)
                    close(sFd)
                    continuation.resume(throwing: OAuthError.exchangeFailed(err))
                    return
                }

                guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    self.sendHTTPResponse(clientFd: clientFd, success: false, message: "No authorization code found.")
                    close(clientFd)
                    close(sFd)
                    continuation.resume(throwing: OAuthError.invalidResponse("Missing code parameter"))
                    return
                }

                self.sendHTTPResponse(clientFd: clientFd, success: true, message: "Authentication successful! You can close this tab and return to RaindropShot.")
                close(clientFd)
                close(sFd)

                continuation.resume(returning: code)
            }
        }
    }

    private func sendHTTPResponse(clientFd: Int32, success: Bool, message: String) {
        let title = success ? "Raindrop Connected" : "Connection Failed"
        let statusColor = success ? "#38bdf8" : "#f87171"
        let heading = success ? "✓ Connected to Raindrop" : "❌ Connection Failed"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>\(title)</title>
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              display: flex;
              align-items: center;
              justify-content: center;
              height: 100vh;
              margin: 0;
              background: #0f172a;
              color: #f8fafc;
            }
            .card {
              background: #1e293b;
              border: 1px solid #334155;
              padding: 40px 48px;
              border-radius: 16px;
              box-shadow: 0 10px 30px rgba(0,0,0,0.4);
              text-align: center;
              max-width: 420px;
            }
            h1 { font-size: 22px; margin: 0 0 12px; color: \(statusColor); }
            p { font-size: 14px; margin: 0; color: #94a3b8; line-height: 1.5; }
          </style>
        </head>
        <body>
          <div class="card">
            <h1>\(heading)</h1>
            <p>\(message)</p>
          </div>
        </body>
        </html>
        """

        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
        let full = header + html
        _ = full.utf8CString.withUnsafeBufferPointer { ptr in
            write(clientFd, ptr.baseAddress, full.utf8.count)
        }
    }
}
