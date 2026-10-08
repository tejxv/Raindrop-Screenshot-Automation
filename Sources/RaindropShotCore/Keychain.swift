import Foundation
import Security

public enum KeychainError: LocalizedError, Equatable {
    case itemNotFound
    case duplicateItem
    case unexpectedData
    case unhandledError(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in Keychain"
        case .duplicateItem:
            return "Item already exists in Keychain"
        case .unexpectedData:
            return "Invalid data retrieved from Keychain"
        case .unhandledError(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error (\(status)): \(msg)"
        }
    }
}

public protocol KeychainProtocol: Sendable {
    func saveToken(_ token: String) throws
    func readToken() throws -> String
    func deleteToken() throws
    func hasToken() -> Bool
}

public struct KeychainHelper: KeychainProtocol, Sendable {
    public let service: String
    public let account: String

    public init(service: String = AppIdentity.keychainService, account: String = AppIdentity.keychainAccount) {
        self.service = service
        self.account = account
    }

    public func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Primary: CLI with -A and -U to ensure seamless cross-process and helper access
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password",
            "-a", account,
            "-s", service,
            "-w", trimmed,
            "-A",
            "-U"
        ]
        process.standardError = pipe
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return
            }
        }

        // Fallback: SecItemAdd
        try? deleteToken()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func readToken() throws -> String {
        // Fast path: Try /usr/bin/security CLI first.
        // It never blocks on GUI dialogs or ACL mismatches for ad-hoc builds.
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                    return str
                }
            } else if process.terminationStatus == 44 { // errSecItemNotFound
                throw KeychainError.itemNotFound
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if status == errSecItemNotFound {
            throw KeychainError.itemNotFound
        }

        throw KeychainError.unhandledError(status: status)
    }

    public func deleteToken() throws {
        // CLI delete first
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", service, "-a", account]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        _ = try? process.run()
        process.waitUntilExit()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    public func hasToken() -> Bool {
        (try? readToken()) != nil
    }
}

public final class MockKeychain: KeychainProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(initialToken: String? = nil) {
        self.token = initialToken
    }

    public func saveToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func readToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let t = token, !t.isEmpty else {
            throw KeychainError.itemNotFound
        }
        return t
    }

    public func deleteToken() throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = nil
    }

    public func hasToken() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil && !(token?.isEmpty ?? true)
    }
}
