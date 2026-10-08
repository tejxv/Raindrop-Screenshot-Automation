import Foundation
import UserNotifications

public struct OutboxNotification: Codable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let body: String
    public let category: String
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, body: String, category: String = "general", createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.createdAt = createdAt
    }
}

public struct NotificationManager: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths = .standard) {
        self.paths = paths
    }

    /// Enqueues a notification to `outbox.json` and attempts immediate posting if possible.
    public func notify(title: String, body: String, category: String = "alert") {
        let notification = OutboxNotification(title: title, body: body, category: category)
        appendOutbox(notification)
        postNativeNotification(title: title, body: body)
    }

    /// Appends to the JSON outbox atomically.
    public func appendOutbox(_ notification: OutboxNotification) {
        var items: [OutboxNotification] = (try? JSONStore.read([OutboxNotification].self, from: paths.outbox)) ?? []
        items.append(notification)
        // Keep at most 20 recent notifications
        if items.count > 20 {
            items = Array(items.suffix(20))
        }
        try? JSONStore.write(items, to: paths.outbox)
    }

    /// Reads and clears all pending notifications in outbox.
    public func drainOutbox() -> [OutboxNotification] {
        guard let items = try? JSONStore.read([OutboxNotification].self, from: paths.outbox) else {
            return []
        }
        try? FileManager.default.removeItem(at: paths.outbox)
        return items
    }

    /// Dispatches a notification using NSUserNotification / osascript fallback for headless worker.
    private func postNativeNotification(title: String, body: String) {
        // Escape quotes for AppleScript display notification
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
