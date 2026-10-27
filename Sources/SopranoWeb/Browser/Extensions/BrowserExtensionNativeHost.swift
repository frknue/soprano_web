import Foundation

/// An extension's notification as the Mac shows it: Chrome's options
/// (`title`, `message`, `contextMessage`, list `items`, `progress`, up to
/// two `buttons`, `silent`) mapped onto one Notification Center entry.
struct BrowserExtensionNotification: Equatable, Sendable {
    var extensionID: String
    var notificationID: String
    var title: String
    var subtitle: String
    var body: String
    var buttons: [String]
    var silent: Bool

    /// Notification Center's identifier: the same id posted again replaces
    /// the entry; two extensions' ids never meet.
    var identifier: String { Self.identifier(extensionID: extensionID, notificationID: notificationID) }

    /// Chrome shows at most two buttons.
    static let maximumButtons = 2

    init(extensionID: String, notificationID: String, options: [String: Any]) {
        self.extensionID = extensionID
        self.notificationID = notificationID
        title = options["title"] as? String ?? ""
        subtitle = options["contextMessage"] as? String ?? ""
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
    /// Shows it; asks macOS for permission the first time (and only then).
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

    let poster: any BrowserExtensionNotificationPosting
    /// Starts the background of an extension with events waiting.
    var wake: (String) -> Void = { _ in }
    /// The extension's open pages (its popup, its pages in tabs) as
    /// `clients.matchAll` lists them: `{ url, visible, focused }`.
    var pages: (String) -> [[String: Any]] = { _ in [] }
    /// Live notifications: extension id → notification id → its options.
    private(set) var notifications: [String: [String: [String: Any]]] = [:]
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
            return await poster.permissionLevel()
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
    /// replaced. Returns the id.
    private func createNotification(extensionID: String, args: [Any]) async throws -> String {
        let api = "notifications.create"
        var id = args.isEmpty ? "" : try string(args, 0, api)
        if id.isEmpty { id = UUID().uuidString }
        let options = try options(args, 1, api)
        try await poster.post(BrowserExtensionNotification(extensionID: extensionID, notificationID: id, options: options))
        notifications[extensionID, default: [:]][id] = options
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
        try await poster.post(BrowserExtensionNotification(extensionID: extensionID, notificationID: id, options: options))
        notifications[extensionID]?[id] = options
        return true
    }

    /// `clear(id)`: true when it was live.
    private func clearNotification(extensionID: String, id: String) -> Bool {
        guard notifications[extensionID]?.removeValue(forKey: id) != nil else { return false }
        if notifications[extensionID]?.isEmpty == true { notifications[extensionID] = nil }
        poster.remove(identifiers: [BrowserExtensionNotification.identifier(extensionID: extensionID, notificationID: id)])
        return true
    }

    /// Someone clicked, pressed a button of, or closed a notification.
    func respond(_ response: Response, extensionID: String, notificationID: String) {
        switch response {
        case .clicked:
            send("notifications.onClicked", [notificationID], to: extensionID)
        case let .button(index):
            send("notifications.onButtonClicked", [notificationID, index], to: extensionID)
        case let .closed(byUser):
            notifications[extensionID]?[notificationID] = nil
            if notifications[extensionID]?.isEmpty == true { notifications[extensionID] = nil }
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
        sinks[extensionID] = nil
        pendingEvents[extensionID] = nil
    }
}

extension BrowserExtensionNotification {
    static func identifier(extensionID: String, notificationID: String) -> String {
        "extension/\(extensionID)/\(notificationID)"
    }
}
