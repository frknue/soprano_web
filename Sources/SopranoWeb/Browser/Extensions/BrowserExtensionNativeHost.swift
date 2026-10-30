import Foundation

/// An extension's notification as the Mac shows it: Chrome's options
/// (`title`, `message`, `contextMessage`, list `items`, `progress`, up to
/// two `buttons`, `silent`) mapped onto one Notification Center entry. The
/// subtitle names the extension that posted it (the extension can't set
/// it); its `contextMessage` is the body's last line.
struct BrowserExtensionNotification: Equatable, Sendable {
    var extensionID: String
    var notificationID: String
    var title: String
    /// The extension's display name.
    var subtitle: String
    var body: String
    var buttons: [String]
    var silent: Bool

    /// Notification Center's identifier: the same id posted again replaces
    /// the entry; two extensions' ids never meet.
    var identifier: String { Self.identifier(extensionID: extensionID, notificationID: notificationID) }

    /// Chrome shows at most two buttons.
    static let maximumButtons = 2

    init(extensionID: String, extensionName: String, notificationID: String, options: [String: Any]) {
        self.extensionID = extensionID
        self.notificationID = notificationID
        title = options["title"] as? String ?? ""
        subtitle = extensionName
        var lines = [options["message"] as? String ?? ""].filter { !$0.isEmpty }
        for item in options["items"] as? [Any] ?? [] {
            guard let item = item as? [String: Any] else { continue }
            let line = [item["title"] as? String, item["message"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !line.isEmpty { lines.append(line) }
        }
        if let progress = (options["progress"] as? NSNumber)?.intValue {
            lines.append("\(min(max(progress, 0), 100)) %")
        }
        if let context = options["contextMessage"] as? String, !context.isEmpty {
            lines.append(context)
        }
        body = lines.joined(separator: "\n")
        buttons = (options["buttons"] as? [Any] ?? [])
            .compactMap { ($0 as? [String: Any])?["title"] as? String }
            .prefix(Self.maximumButtons)
            .map { $0 }
        silent = options["silent"] as? Bool ?? false
    }
}

/// Where the host posts and removes notifications (Notification Center in
/// the app, a recorder in tests).
@MainActor
protocol BrowserExtensionNotificationPosting: AnyObject {
    /// True while macOS hasn't been asked yet whether the app may show
    /// notifications (asking would bring up the system prompt).
    func authorizationIsUndetermined() async -> Bool
    /// Asks macOS for permission (the system prompt the first time, the
    /// stored answer after); true when allowed.
    func requestAuthorization() async -> Bool
    /// Shows it; never asks macOS: fails while the app's permission is
    /// undetermined or turned off.
    func post(_ notification: BrowserExtensionNotification) async throws
    func remove(identifiers: [String])
    /// `"granted"` or `"denied"`, without asking.
    func permissionLevel() async -> String
}

/// The app's side of the shim (`BrowserExtensionShims`): answers its
/// `runtime.sendNativeMessage("soprano", { api, args })` calls with
/// `{ value }` or `{ error }`, and sends events to each background over its
/// `soprano.events` port, holding them while no port is open (the worker
/// is woken to take them).
///
/// It answers only an extension whose installed copy carries the shim, and
/// only the stand-ins that copy carries (`BrowserExtensionRecord.standIns`):
/// any other extension calling the application id gets an error.
@MainActor
final class BrowserExtensionNativeHost {
    /// What the app hands an extension's event port.
    typealias Sink = ([String: Any]) -> Void

    enum Response: Equatable {
        case clicked
        case button(Int)
        case closed(byUser: Bool)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let maximumPendingEvents = 64
    /// Live notifications an extension may keep; creating one more takes
    /// down its oldest (as if closed by the system, `onClosed` with
    /// `byUser` false) rather than failing, as Chrome's own center drops
    /// the oldest when full.
    static let maximumNotifications = 100

    let poster: any BrowserExtensionNotificationPosting
    /// Starts the background of an extension with events waiting.
    var wake: (String) -> Void = { _ in }
    /// The extension's open pages (its popup, its pages in tabs) as
    /// `clients.matchAll` lists them: `{ url, visible, focused }`.
    var pages: (String) -> [[String: Any]] = { _ in [] }
    /// The extension's display name, its notifications' subtitle (nil:
    /// the extension id is shown instead).
    var displayName: @MainActor (String) -> String? = { _ in nil }
    /// Asks the user, in the app, whether the extension may show
    /// notifications: true or false, nil when nobody could answer (no
    /// window). Asked before an extension's notification would bring up
    /// macOS's own prompt (the app's permission still undetermined), so an
    /// extension never triggers that prompt unannounced; once the app's
    /// permission is decided it isn't asked.
    var confirmNotifications: @MainActor (_ extensionID: String) async -> Bool? = { _ in false }
    /// Live notifications: extension id → notification id → its options.
    private(set) var notifications: [String: [String: [String: Any]]] = [:]
    /// Live notification ids per extension, the oldest first.
    private var notificationOrder: [String: [String]] = [:]
    /// Extensions the user refused notifications this session: not asked
    /// again, their notifications fail.
    private var refusedNotifications: Set<String> = []
    /// Extensions the user allowed this session: not asked in the app again.
    private var allowedNotifications: Set<String> = []
    /// One authorization per extension while it runs (the in-app question
    /// and then macOS's prompt): every notification meanwhile waits for it.
    private var authorizations: [String: Task<Authorization, Never>] = [:]

    private enum Authorization {
        case allowed, refused, unanswered, systemDenied
    }
    private var sinks: [String: Sink] = [:]
    private(set) var pendingEvents: [String: [[String: Any]]] = [:]

    init(poster: any BrowserExtensionNotificationPosting) {
        self.poster = poster
    }

    // MARK: - Messages

    /// The reply to one shim message from `extensionID`, whose copy carries
    /// `standIns`.
    func answer(_ message: Any, extensionID: String, standIns: [String]) async -> [String: Any] {
        do {
            return ["value": try await perform(message, extensionID: extensionID, standIns: standIns) ?? NSNull()]
        } catch {
            return ["error": (error as? Failure)?.description ?? error.localizedDescription]
        }
    }

    private func perform(_ message: Any, extensionID: String, standIns: [String]) async throws -> Any? {
        guard !standIns.isEmpty else {
            throw Failure(description: "No native messaging host \(BrowserExtensionShims.application).")
        }
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            throw Failure(description: "The message names no API.")
        }
        guard let args = (body["args"] ?? []) as? [Any] else {
            throw Failure(description: "\(api): arguments must be a list.")
        }
        let standIn = api.split(separator: ".").first.map(String.init) ?? ""
        guard standIns.contains(standIn) else {
            throw Failure(description: "\(api) is not available to this extension.")
        }
        switch api {
        case "notifications.create":
            return try await createNotification(extensionID: extensionID, args: args)
        case "notifications.update":
            return try await updateNotification(extensionID: extensionID, args: args)
        case "notifications.clear":
            return clearNotification(extensionID: extensionID, id: try string(args, 0, api))
        case "notifications.getAll":
            return Dictionary(uniqueKeysWithValues: (notifications[extensionID] ?? [:]).keys.map { ($0, true) })
        case "notifications.getPermissionLevel":
            return refusedNotifications.contains(extensionID) ? "denied" : await poster.permissionLevel()
        case "clients.pages":
            return pages(extensionID)
        default:
            throw Failure(description: "\(api) is not supported.")
        }
    }

    private func string(_ args: [Any], _ index: Int, _ api: String) throws -> String {
        guard index < args.count, let value = args[index] as? String else {
            throw Failure(description: "\(api): argument \(index + 1) must be a string.")
        }
        return value
    }

    private func options(_ args: [Any], _ index: Int, _ api: String) throws -> [String: Any] {
        guard index < args.count else { return [:] }
        guard let value = args[index] as? [String: Any] else {
            throw Failure(description: "\(api): argument \(index + 1) must be an object.")
        }
        return value
    }

    // MARK: - Notifications

    /// `create([id], options)`: an empty id gets a new one; an id in use is
    /// replaced (and counts as the newest). Beyond `maximumNotifications`
    /// the oldest is taken down. Returns the id.
    private func createNotification(extensionID: String, args: [Any]) async throws -> String {
        let api = "notifications.create"
        var id = args.isEmpty ? "" : try string(args, 0, api)
        if id.isEmpty { id = UUID().uuidString }
        let options = try options(args, 1, api)
        try await authorizeNotifications(extensionID: extensionID)
        try await poster.post(notification(extensionID: extensionID, id: id, options: options))
        notifications[extensionID, default: [:]][id] = options
        var order = (notificationOrder[extensionID] ?? []).filter { $0 != id }
        order.append(id)
        notificationOrder[extensionID] = order
        while order.count > Self.maximumNotifications {
            let oldest = order.removeFirst()
            guard removeNotification(extensionID: extensionID, id: oldest) else { continue }
            poster.remove(identifiers: [BrowserExtensionNotification.identifier(extensionID: extensionID, notificationID: oldest)])
            send("notifications.onClosed", [oldest, false], to: extensionID)
        }
        return id
    }

    /// `update(id, options)`: merged into a live notification, shown again.
    /// False for one that isn't live.
    private func updateNotification(extensionID: String, args: [Any]) async throws -> Bool {
        let api = "notifications.update"
        let id = try string(args, 0, api)
        let changes = try options(args, 1, api)
        guard var options = notifications[extensionID]?[id] else { return false }
        options.merge(changes) { _, new in new }
        try await authorizeNotifications(extensionID: extensionID)
        try await poster.post(notification(extensionID: extensionID, id: id, options: options))
        notifications[extensionID]?[id] = options
        return true
    }

    /// `clear(id)`: true when it was live.
    private func clearNotification(extensionID: String, id: String) -> Bool {
        guard removeNotification(extensionID: extensionID, id: id) else { return false }
        poster.remove(identifiers: [BrowserExtensionNotification.identifier(extensionID: extensionID, notificationID: id)])
        return true
    }

    /// Forgets a live notification (without taking it down); false when it
    /// wasn't live.
    private func removeNotification(extensionID: String, id: String) -> Bool {
        guard notifications[extensionID]?.removeValue(forKey: id) != nil else { return false }
        notificationOrder[extensionID]?.removeAll { $0 == id }
        if notifications[extensionID]?.isEmpty == true {
            notifications[extensionID] = nil
            notificationOrder[extensionID] = nil
        }
        return true
    }

    /// The notification as shown, under the extension's display name (its
    /// id when it has none).
    private func notification(extensionID: String, id: String, options: [String: Any]) -> BrowserExtensionNotification {
        let name = displayName(extensionID).flatMap { $0.isEmpty ? nil : $0 } ?? extensionID
        return BrowserExtensionNotification(extensionID: extensionID, extensionName: name, notificationID: id, options: options)
    }

    /// Before an extension's notification would bring up macOS's prompt
    /// (the app's permission undetermined), the user is asked in the app
    /// first (`confirmNotifications`), once per extension and session: only
    /// a yes asks macOS; a no fails this and every later notification of
    /// the extension. A decided permission asks nothing.
    private func authorizeNotifications(extensionID: String) async throws {
        let refused = Failure(description: "Notifications were not allowed for this extension.")
        if refusedNotifications.contains(extensionID) { throw refused }
        let task: Task<Authorization, Never>
        if let running = authorizations[extensionID] {
            task = running
        } else {
            guard await poster.authorizationIsUndetermined() else { return }
            if let running = authorizations[extensionID] {
                task = running
            } else {
                let allowedBefore = allowedNotifications.contains(extensionID)
                task = Task {
                    if !allowedBefore {
                        guard let answer = await self.confirmNotifications(extensionID) else { return .unanswered }
                        guard answer else { return .refused }
                    }
                    return await self.poster.requestAuthorization() ? .allowed : .systemDenied
                }
                authorizations[extensionID] = task
            }
        }
        let result = await task.value
        if authorizations[extensionID] == task { authorizations[extensionID] = nil }
        switch result {
        case .allowed:
            allowedNotifications.insert(extensionID)
        case .refused:
            refusedNotifications.insert(extensionID)
            throw refused
        case .unanswered:
            throw Failure(description: "Notifications need a window to ask in; try again with one open.")
        case .systemDenied:
            allowedNotifications.insert(extensionID)
            throw BrowserNotificationCenter.PostError.notAuthorized
        }
    }

    /// Someone clicked, pressed a button of, or closed a notification.
    func respond(_ response: Response, extensionID: String, notificationID: String) {
        switch response {
        case .clicked:
            send("notifications.onClicked", [notificationID], to: extensionID)
        case let .button(index):
            send("notifications.onButtonClicked", [notificationID, index], to: extensionID)
        case let .closed(byUser):
            _ = removeNotification(extensionID: extensionID, id: notificationID)
            send("notifications.onClosed", [notificationID, byUser], to: extensionID)
        }
    }

    // MARK: - Events

    /// The background's event port opened: waiting events go first.
    func attach(extensionID: String, sink: @escaping Sink) {
        sinks[extensionID] = sink
        for event in pendingEvents.removeValue(forKey: extensionID) ?? [] {
            sink(event)
        }
    }

    func detach(extensionID: String) {
        sinks[extensionID] = nil
    }

    func send(_ event: String, _ args: [Any], to extensionID: String) {
        let message: [String: Any] = ["event": event, "args": args]
        if let sink = sinks[extensionID] {
            sink(message)
            return
        }
        var queue = pendingEvents[extensionID] ?? []
        queue.append(message)
        if queue.count > Self.maximumPendingEvents {
            queue.removeFirst(queue.count - Self.maximumPendingEvents)
        }
        pendingEvents[extensionID] = queue
        wake(extensionID)
    }

    /// The extension is gone (removed or disabled): its notifications are
    /// taken down, its port and waiting events dropped.
    func forget(_ extensionID: String) {
        if let live = notifications.removeValue(forKey: extensionID), !live.isEmpty {
            poster.remove(identifiers: live.keys.map {
                BrowserExtensionNotification.identifier(extensionID: extensionID, notificationID: $0)
            })
        }
        notificationOrder[extensionID] = nil
        sinks[extensionID] = nil
        pendingEvents[extensionID] = nil
        refusedNotifications.remove(extensionID)
        allowedNotifications.remove(extensionID)
    }
}

extension BrowserExtensionNotification {
    static func identifier(extensionID: String, notificationID: String) -> String {
        "extension/\(extensionID)/\(notificationID)"
    }
}
