import AppKit
import UserNotifications

/// Posts web notifications to Notification Center and routes clicks back to
/// the tab that posted them. `UNUserNotificationCenter` needs an app bundle;
/// outside one (the snapshot harness, tests) posting fails with `unavailable`.
@MainActor
final class BrowserNotificationCenter: NSObject {
    struct Click: Sendable {
        let tabID: UUID
        let document: String
        let notificationID: Int
    }

    enum PostError: Error {
        case unavailable
        case notAuthorized
    }

    static let shared = BrowserNotificationCenter()

    var onClick: ((Click) -> Void)?

    nonisolated private static let tabKey = "tabID"
    nonisolated private static let documentKey = "document"
    nonisolated private static let notificationKey = "notificationID"

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
