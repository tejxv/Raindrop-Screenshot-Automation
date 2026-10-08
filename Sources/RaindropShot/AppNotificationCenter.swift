import AppKit
import UserNotifications
import RaindropShotCore

@MainActor
public final class AppNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = AppNotificationCenter()

    public static let categoryUploadSuccess = "com.tejxv.RaindropShot.category.upload-success"
    public static let categoryUploadError   = "com.tejxv.RaindropShot.category.upload-error"
    public static let categoryAuthError     = "com.tejxv.RaindropShot.category.auth-error"

    public static let actionCopyLink        = "ACTION_COPY_LINK"
    public static let actionShowInFinder    = "ACTION_SHOW_IN_FINDER"
    public static let actionCleanNow        = "ACTION_CLEAN_NOW"
    public static let actionSignIn          = "ACTION_SIGN_IN"
    public static let actionOpenSettings    = "ACTION_OPEN_SETTINGS"

    private let paths: AppPaths
    public var onOpenAuth: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onCleanNow: (() -> Void)?
    public var onOpenFolder: (() -> Void)?

    public init(paths: AppPaths = .standard) {
        self.paths = paths
        super.init()
    }

    /// Sets up notification center, registers categories, and requests authorization.
    public func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        registerCategories()

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                // Permissions granted
            }
        }
    }

    private func registerCategories() {
        let copyLinkAction = UNNotificationAction(
            identifier: Self.actionCopyLink,
            title: "Copy Link",
            options: .foreground
        )

        let showInFinderAction = UNNotificationAction(
            identifier: Self.actionShowInFinder,
            title: "Show in Finder",
            options: .foreground
        )

        let cleanNowAction = UNNotificationAction(
            identifier: Self.actionCleanNow,
            title: "Clean Up Now",
            options: .destructive
        )

        let uploadSuccessCategory = UNNotificationCategory(
            identifier: Self.categoryUploadSuccess,
            actions: [copyLinkAction, showInFinderAction, cleanNowAction],
            intentIdentifiers: [],
            options: []
        )

        let signInAction = UNNotificationAction(
            identifier: Self.actionSignIn,
            title: "Sign In",
            options: .foreground
        )

        let authErrorCategory = UNNotificationCategory(
            identifier: Self.categoryAuthError,
            actions: [signInAction],
            intentIdentifiers: [],
            options: []
        )

        let settingsAction = UNNotificationAction(
            identifier: Self.actionOpenSettings,
            title: "Settings",
            options: .foreground
        )

        let uploadErrorCategory = UNNotificationCategory(
            identifier: Self.categoryUploadError,
            actions: [settingsAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            uploadSuccessCategory,
            authErrorCategory,
            uploadErrorCategory
        ])
    }

    /// Drains any pending notifications queued by the worker and displays them natively.
    public func drainOutboxAndDeliver() {
        let mgr = NotificationManager(paths: paths)
        let pending = mgr.drainOutbox()
        guard !pending.isEmpty else { return }

        for item in pending {
            deliverNotification(item)
        }
    }

    /// Directly delivers a high-priority notification to the user.
    public func deliverNotification(
        title: String,
        body: String,
        category: String = "general"
    ) {
        let item = OutboxNotification(title: title, body: body, category: category)
        deliverNotification(item)
    }

    private func deliverNotification(_ item: OutboxNotification) {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.threadIdentifier = "com.tejxv.RaindropShot.notifications"

        switch item.category {
        case "success":
            content.categoryIdentifier = Self.categoryUploadSuccess
        case "auth":
            content.categoryIdentifier = Self.categoryAuthError
        case "error", "rejected":
            content.categoryIdentifier = Self.categoryUploadError
        default:
            break
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Display notification banner and play sound even when app is frontmost
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let categoryId = response.notification.request.content.categoryIdentifier

        Task { @MainActor in
            switch actionId {
            case Self.actionCopyLink:
                let state = StateStore.load(self.paths, now: Date()).state
                if let last = state.records.filter({ $0.uploadedAt != nil }).sorted(by: { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }).first {
                    let link = last.raindropId.map { "https://app.raindrop.io/my/0/item/\($0)" } ?? last.raindropLink
                    if let link = link, let url = URL(string: link) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(link, forType: .string)
                        pb.writeObjects([url as NSURL])
                    }
                }
            case Self.actionShowInFinder:
                self.onOpenFolder?()
            case Self.actionCleanNow:
                self.onCleanNow?()
            case Self.actionSignIn:
                self.onOpenAuth?()
            case Self.actionOpenSettings:
                self.onOpenSettings?()
            case UNNotificationDefaultActionIdentifier:
                // User clicked the banner itself
                if categoryId == Self.categoryAuthError {
                    self.onOpenAuth?()
                } else if categoryId == Self.categoryUploadSuccess {
                    self.onOpenFolder?()
                }
            default:
                break
            }
        }
        completionHandler()
    }
}
