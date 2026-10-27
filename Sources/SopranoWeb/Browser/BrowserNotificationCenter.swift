import AppKit
import UserNotifications

/// Posts web notifications to Notification Center and routes clicks back to
/// the tab that posted them, and extensions' notifications
/// (`chrome.notifications`, `BrowserExtensionNativeHost`) with their clicks,
/// buttons and dismissals back to the extension. `UNUserNotificationCenter`
/// needs an app bundle; outside one (the snapshot harness, tests) posting
/// fails with `unavailable`.
@MainActor
final class BrowserNotificationCenter: NSObject {
    struct Click: Sendable {
        let tabID: UUID
        let document: String
        let notificationID: Int
    }

    enum PostError: Error, CustomStringConvertible {
        case unavailable
        case notAuthorized

        var description: String {
            switch self {
            case .unavailable: "Notifications are unavailable."
            case .notAuthorized: "Notifications are turned off for this app in System Settings."
            }
        }
    }

    static let shared = BrowserNotificationCenter()

    var onClick: ((Click) -> Void)?
    /// An extension's notification was clicked, a button pressed, or it
    /// was dismissed: extension id, notification id, what happened.
    var onExtensionResponse: ((String, String, BrowserExtensionNativeHost.Response) -> Void)?
    /// The button sets of extension notifications registered as categories.
    private var extensionCategories: [String: UNNotificationCategory] = [:]

    nonisolated private static let tabKey = "tabID"
    nonisolated private static let documentKey = "document"
    nonisolated private static let notificationKey = "notificationID"
    nonisolated private static let extensionKey = "extensionID"
    nonisolated private static let extensionNotificationKey = "extensionNotificationID"
    nonisolated private static let buttonPrefix = "button"

    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        guard Self.isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            center.delegate = self
        }
        return center
    }

    /// Asks macOS for permission to show notifications; called the first
    /// time a site is allowed. Later calls return the stored answer.
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(
        tabID: UUID,
        host: String,
        document: String,
        notificationID: Int,
        title: String,
        body: String,
        tag: String,
        silent: Bool
    ) async throws {
        let center = try await authorizedCenter()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = host
        content.body = body
        content.sound = silent ? nil : .default
        content.threadIdentifier = host
        content.userInfo = [
            Self.tabKey: tabID.uuidString,
            Self.documentKey: document,
            Self.notificationKey: notificationID,
        ]
        let request = UNNotificationRequest(
            identifier: Self.identifier(tabID: tabID, document: document, notificationID: notificationID, tag: tag),
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func remove(tabID: UUID, document: String, notificationID: Int, tag: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [
            Self.identifier(tabID: tabID, document: document, notificationID: notificationID, tag: tag),
        ])
    }

    /// A tagged notification replaces the tab's earlier one with that tag.
    private static func identifier(tabID: UUID, document: String, notificationID: Int, tag: String) -> String {
        tag.isEmpty
            ? "\(tabID.uuidString)/\(document)/\(notificationID)"
            : "\(tabID.uuidString)/tag/\(tag)"
    }

    fileprivate func handleClick(_ click: Click) {
        onClick?(click)
    }

    fileprivate func handleExtensionResponse(_ extensionID: String, _ notificationID: String, _ response: BrowserExtensionNativeHost.Response) {
        onExtensionResponse?(extensionID, notificationID, response)
    }

    /// The center once macOS allows notifications: asks the first time
    /// (only when something is posted), refuses when turned off.
    private func authorizedCenter() async throws -> UNUserNotificationCenter {
        guard let center else { throw PostError.unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard await requestAuthorization() else { throw PostError.notAuthorized }
        case .denied:
            throw PostError.notAuthorized
        default:
            break
        }
        return center
    }

    /// The category of an extension notification with `buttons`: its
    /// buttons as actions, and a dismissal reported (`onClosed`).
    private func extensionCategory(buttons: [String], in center: UNUserNotificationCenter) -> String {
        let identifier = (["extension"] + buttons).joined(separator: "\u{1F}")
        guard extensionCategories[identifier] == nil else { return identifier }
        let actions = buttons.enumerated().map { index, title in
            UNNotificationAction(identifier: "\(Self.buttonPrefix)\(index)", title: title, options: [.foreground])
        }
        extensionCategories[identifier] = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories(Set(extensionCategories.values))
        return identifier
    }
}

extension BrowserNotificationCenter: BrowserExtensionNotificationPosting {
    func post(_ notification: BrowserExtensionNotification) async throws {
        let center = try await authorizedCenter()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = notification.silent ? nil : .default
        content.threadIdentifier = notification.extensionID
        content.categoryIdentifier = extensionCategory(buttons: notification.buttons, in: center)
        content.userInfo = [
            Self.extensionKey: notification.extensionID,
            Self.extensionNotificationKey: notification.notificationID,
        ]
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }

    func remove(identifiers: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: identifiers)
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func permissionLevel() async -> String {
        guard let center else { return "granted" }
        return await center.notificationSettings().authorizationStatus == .denied ? "denied" : "granted"
    }
}

extension BrowserNotificationCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if let extensionID = info[Self.extensionKey] as? String,
           let notificationID = info[Self.extensionNotificationKey] as? String
        {
            let reply: BrowserExtensionNativeHost.Response? = switch action {
            case UNNotificationDefaultActionIdentifier: .clicked
            case UNNotificationDismissActionIdentifier: .closed(byUser: true)
            default: Int(action.dropFirst(Self.buttonPrefix.count)).map { .button($0) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let reply {
                        BrowserNotificationCenter.shared.handleExtensionResponse(extensionID, notificationID, reply)
                    }
                }
            }
            completionHandler()
            return
        }
        let click = (info[Self.tabKey] as? String).flatMap(UUID.init(uuidString:)).map { tabID in
            Click(
                tabID: tabID,
                document: info[Self.documentKey] as? String ?? "",
                notificationID: (info[Self.notificationKey] as? NSNumber)?.intValue ?? 0
            )
        }
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isDefaultAction, let click {
                    BrowserNotificationCenter.shared.handleClick(click)
                }
            }
        }
        completionHandler()
    }
}
