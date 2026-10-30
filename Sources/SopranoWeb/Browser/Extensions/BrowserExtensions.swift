import AppKit
import CryptoKit
import WebKit

/// Chrome extensions on `WKWebExtension`, owned by the window manager: the
/// one app-wide `WKWebExtensionController` every tab's configuration
/// carries (`makeTabConfiguration`), the installed extensions
/// (`BrowserExtensionStore`) loaded into it as contexts with stable
/// `chrome-extension://<id>/` origins, installs from the Chrome Web Store
/// (CRX3 verified as Chrome verifies a store install) or an unpacked
/// folder, the daily update check, and the tab and window adapters
/// (`BrowserExtensionAdapters.swift`). The delegate side lives in
/// `BrowserExtensions+Delegate.swift`.
///
/// Extensions are app-wide: one controller serves every Space, each tab
/// keeps its own data store. Private web views carry the controller too;
/// WebKit runs an extension in them only when its context has
/// `hasAccessToPrivateData` (Settings ▸ Extensions ▸ "Allow in private
/// windows"), recognizing them by their non-persistent data store and
/// their own user content controller.
@MainActor
final class BrowserExtensions: NSObject {
    /// The scheme of every extension's pages (`chrome-extension://<id>/`),
    /// so extensions that build their own URLs keep working and storage
    /// survives relaunches.
    static let scheme = "chrome-extension"
    /// The controller's storage: the same for every launch of this app
    /// (the dev app has its own WebKit container).
    static let controllerIdentifier = UUID(uuidString: "5F0C8E2A-3D41-4E6B-9A7C-2B1D0E4F6A01")!
    /// How often installed Web Store extensions are checked for updates.
    static let updateInterval: TimeInterval = 86_400

    enum Storage {
        /// The app: extension storage kept across launches.
        case persistent
        /// The harness: a controller of its own for the run, emptied at
        /// the end (`removeAllData`). Not `.nonPersistent()`: on macOS 26
        /// its extensions get no events (`tabs.onCreated`,
        /// `tabs.onUpdated`, `runtime.onInstalled`), while the same
        /// extension under a persistent controller gets them all.
        case volatile
    }

    enum InstallError: Error, CustomStringConvertible {
        case badInput(String)
        case notAFolder(String)
        case unreadable(String)
        case notInstalled(String)
        case privateNotAllowed
        /// The id is installed from another source (the Web Store, another
        /// folder): a folder carrying a store extension's `key` would take
        /// over its origin, data and grants.
        case sourceChanged(id: String, installed: BrowserExtensionRecord.Source, new: BrowserExtensionRecord.Source)
        case cancelled

        var description: String {
            switch self {
            case let .badInput(input): "“\(input)” is not an extension id, Chrome Web Store link or folder"
            case let .notAFolder(path): "\(path) is not a folder with a manifest.json"
            case let .unreadable(reason): "WebKit can't load the extension: \(reason)"
            case let .notInstalled(id): "No extension \(id) is installed. Use `extensions` to list them."
            case .privateNotAllowed: "The extension doesn't allow running in private windows (incognito: not_allowed)."
            case let .sourceChanged(id, installed, new):
                "\(id) is already installed from \(installed.title). Remove it first (`extension remove \(id)`, "
                    + "which deletes its data) to install it from \(new.title)."
            case .cancelled: "The install was cancelled."
            }
        }
    }

    /// What an install shows before it lands (Settings ▸ Extensions asks;
    /// the CLI prints the lines): the permission list of a new extension,
    /// what an update newly asks for, or a replacement from another source
    /// (its settings and data reset).
    struct InstallReview {
        enum Kind: Equatable {
            case install
            case update
            case replace(installed: BrowserExtensionRecord.Source, new: BrowserExtensionRecord.Source)
        }

        var id: String
        var name: String
        var version: String
        var icon: NSImage?
        var kind: Kind
        /// What it may do, in Chrome's words (an update: only the new).
        var lines: [String]

        var header: String {
            switch kind {
            case .install: "Add “\(name)”? It can:"
            case .update: "“\(name)” \(version) asks for more. It can now also:"
            case let .replace(installed, new):
                "“\(name)” is installed from \(installed.title). Replace it with the one from \(new.title)? "
                    + "Its settings, permissions and stored data are reset. It can:"
            }
        }

        var allowTitle: String {
            switch kind {
            case .install: "Add Extension"
            case .update: "Allow"
            case .replace: "Replace"
            }
        }
    }

    /// Asks the user about an install; false cancels it.
    typealias InstallConfirmation = @MainActor (InstallReview) async -> Bool

    /// What an update asks for beyond what the user already granted or
    /// denied: left ungranted until the user allows it.
    struct Additions: Equatable, Sendable {
        var permissions: [String] = []
        var matchPatterns: [String] = []

        var isEmpty: Bool { permissions.isEmpty && matchPatterns.isEmpty }

        /// The items of `self` that `other` lists too, in `self`'s order.
        func intersection(_ other: Additions) -> Additions {
            Additions(
                permissions: permissions.filter(other.permissions.contains),
                matchPatterns: matchPatterns.filter(other.matchPatterns.contains)
            )
        }

        /// The items of `self` that `other` doesn't list.
        func subtracting(_ other: Additions) -> Additions {
            Additions(
                permissions: permissions.filter { !other.permissions.contains($0) },
                matchPatterns: matchPatterns.filter { !other.matchPatterns.contains($0) }
            )
        }

        /// The permission sheet's lines.
        @MainActor var lines: [String] {
            BrowserExtensionPermissionPrompt.describe(
                permissions: permissions.map(WKWebExtension.Permission.init(rawValue:)),
                patterns: matchPatterns.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
            )
        }
    }

    /// A native-messaging answer for an application identifier (P2's
    /// stand-ins answer `runtime.sendNativeMessage` here).
    typealias NativeMessageHandler = @MainActor (_ message: Any, _ context: WKWebExtensionContext) async throws -> Any?
    /// A native port for an application identifier; the port stays open
    /// while the handler keeps it.
    typealias NativePortHandler = @MainActor (_ port: WKWebExtension.MessagePort, _ context: WKWebExtensionContext) throws -> Void

    /// A native messaging host: the extensions it answers (Chrome's
    /// `allowed_origins`, by extension id) and its handlers. Any other
    /// extension gets "host not found" before a handler runs.
    struct NativeHost {
        var allows: @MainActor (_ extensionID: String) -> Bool
        var message: NativeMessageHandler?
        var port: NativePortHandler?
    }

    let store: BrowserExtensionStore
    let controller: WKWebExtensionController
    weak var manager: BrowserWindowManager?
    /// Installs, removals, enabling, loading and settings changes.
    let changes = BrowserObservers<Void>()
    /// An action's icon, badge, title or enabled state changed.
    let actionChanges = BrowserObservers<Void>()
    /// Loaded contexts by extension id.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Why an enabled extension isn't loaded, by id.
    private(set) var loadErrors: [String: String] = [:]
    /// Why a loaded extension's background page or worker didn't start.
    private(set) var backgroundErrors: [String: String] = [:]
    /// Extensions being installed or updated right now.
    private(set) var busy: Set<String> = []
    /// Native messaging hosts by application identifier, each with its
    /// allowlist (`allowedNativeHost`).
    var nativeHosts: [String: NativeHost] = [:]
    /// What updates newly asked for and the user hasn't allowed yet, by id.
    private(set) var pendingAdditions: [String: Additions] = [:]
    /// Extensions whose `pendingAdditions` the sheet asked about this launch.
    private var askedAdditions: Set<String> = []
    /// The stand-ins' native side (`BrowserExtensionShims`).
    let nativeHost: BrowserExtensionNativeHost
    /// Each shimmed background's open `soprano.events` port, kept alive here.
    private var eventPorts: [String: WKWebExtension.MessagePort] = [:]
    /// Workers' WebSockets (`soprano.socket` ports), kept alive while open.
    private var sockets: [ObjectIdentifier: BrowserExtensionSocket] = [:]

    private let checksForUpdates: Bool
    private var updateTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    var tabAdapters: [UUID: BrowserExtensionTab] = [:]
    var windowAdapters: [UUID: BrowserExtensionWindow] = [:]
    /// The popup shown by `presentActionPopup`, while open.
    var popup: BrowserExtensionPopup?
    /// Permission prompts waiting for the sheet, oldest first.
    var pendingPrompts: [BrowserExtensionPermissionPrompt] = []
    var promptSheet: BrowserExtensionPermissionSheet?

    init(supportDirectory: URL, storage: Storage, checksForUpdates: Bool) {
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.scheme)
        store = BrowserExtensionStore(supportDirectory: supportDirectory)
        let configuration: WKWebExtensionController.Configuration = switch storage {
        case .persistent: WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        case .volatile: WKWebExtensionController.Configuration(identifier: UUID())
        }
        // Extension pages and workers get the tabs' user agent: WebKit stops
        // extension workers whose agent differs and doesn't restart them.
        configuration.webViewConfiguration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        // The Default Space's store, the one `defaultContext` uses.
        configuration.defaultWebsiteDataStore = .default()
        controller = WKWebExtensionController(configuration: configuration)
        nativeHost = BrowserExtensionNativeHost(poster: BrowserNotificationCenter.shared)
        self.checksForUpdates = checksForUpdates
        super.init()
        controller.delegate = self
        observeContextNotifications()
        installNativeHost()
    }

    /// The shim's application id and ports, answered only for an extension
    /// whose installed copy carries the shim (and, for a socket, the
    /// `webSocket` stand-in): each host's allowlist, checked before its
    /// handler runs.
    private func installNativeHost() {
        nativeHost.wake = { [weak self] id in
            self?.contexts[id]?.loadBackgroundContent { _ in }
        }
        nativeHost.pages = { [weak self] id in
            self?.openPages(of: id) ?? []
        }
        BrowserNotificationCenter.shared.onExtensionResponse = { [weak self] id, notificationID, response in
            self?.nativeHost.respond(response, extensionID: id, notificationID: notificationID)
        }
        nativeHost.displayName = { [weak self] id in
            self?.contexts[id]?.webExtension.displayName ?? self?.store.record(id: id)?.name
        }
        // Before an extension's first notification raises the system
        // prompt, the user is asked in the app, naming the extension.
        nativeHost.confirmNotifications = { [weak self] id in
            guard let self, let context = self.contexts[id] else { return false }
            // Without a window nobody can answer: not a refusal.
            guard self.manager?.activeController?.window != nil else { return nil }
            return await withCheckedContinuation { continuation in
                self.prompt(context, tab: nil, lines: ["Show notifications"]) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        let shimmed: @MainActor (String) -> Bool = { [weak self] id in
            self?.store.record(id: id)?.standIns.isEmpty == false
        }
        nativeHosts[BrowserExtensionShims.application] = NativeHost(allows: shimmed, message: { [weak self] message, context in
            guard let self, let id = self.id(of: context) else { return nil }
            return await self.nativeHost.answer(message, extensionID: id, standIns: self.store.record(id: id)?.standIns ?? [])
        })
        nativeHosts[BrowserExtensionShims.eventsPort] = NativeHost(allows: shimmed, port: { [weak self] port, context in
            guard let self, let id = self.id(of: context) else {
                throw Self.refusal("No native messaging host \(BrowserExtensionShims.eventsPort).")
            }
            self.eventPorts[id]?.disconnect()
            self.eventPorts[id] = port
            port.messageHandler = { _, _ in }
            port.disconnectHandler = { [weak self, weak port] _ in
                guard let self, let port, self.eventPorts[id] === port else { return }
                self.eventPorts[id] = nil
                self.nativeHost.detach(extensionID: id)
            }
            self.nativeHost.attach(extensionID: id) { [weak port] message in
                port?.sendMessage(message, completionHandler: nil)
            }
        })
        nativeHosts[BrowserExtensionShims.socketPort] = NativeHost(allows: { [weak self] id in
            self?.store.record(id: id)?.standIns.contains("webSocket") == true
        }, port: { [weak self] port, context in
            guard let self, let id = self.id(of: context) else {
                throw Self.refusal("No native messaging host \(BrowserExtensionShims.socketPort).")
            }
            guard self.sockets.values.count(where: { $0.extensionID == id }) < BrowserExtensionSocket.maxPerExtension else {
                throw Self.refusal("Too many open WebSockets.")
            }
            let policy = BrowserExtensionSocketPolicy.make(manifest: context.webExtension.manifest) { [weak context] url in
                guard let context else { return false }
                return [.grantedExplicitly, .grantedImplicitly].contains(context.permissionStatus(for: url))
            }
            let socket = BrowserExtensionSocket(port: port, extensionID: id, policy: policy)
            let key = ObjectIdentifier(socket)
            socket.onFinish = { [weak self] in self?.sockets[key] = nil }
            self.sockets[key] = socket
        })
    }

    /// The extension's pages open now, as `clients.matchAll` lists them:
    /// its popup and its pages in tabs (visible when shown in a visible
    /// window; focused in the key window). Private windows count only for
    /// an extension allowed in them.
    func openPages(of id: String) -> [[String: Any]] {
        var pages: [[String: Any]] = []
        if let popup, popup.extensionID == id {
            let url = popup.webView.url ?? popup.url
            pages.append(["url": url.absoluteString, "visible": popup.popover.isShown, "focused": popup.popover.isShown])
        }
        let prefix = "\(Self.scheme)://\(id)/"
        let privateAccess = contexts[id]?.hasAccessToPrivateData == true
        for window in manager?.mostRecentlyActiveFirst(where: { privateAccess || !$0.kind.isPrivate }) ?? [] {
            for tab in window.tabs {
                guard let url = tab.webView.url?.absoluteString, url.hasPrefix(prefix) else { continue }
                let visible = window.selectedTab === tab && window.window?.isVisible == true
                pages.append(["url": url, "visible": visible, "focused": visible && window.window?.isKeyWindow == true])
            }
        }
        return pages
    }

    /// Loads every enabled extension and starts the update check.
    func start(manager: BrowserWindowManager) {
        self.manager = manager
        for record in store.records where record.isEnabled {
            Task { await self.load(record.id) }
        }
        guard checksForUpdates else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkForUpdates(force: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        // A minute after launch, so it never competes with the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            Task { await self.checkForUpdates(force: false) }
        }
    }

    // MARK: - Lookup

    var records: [BrowserExtensionRecord] { store.records }

    func context(id: String) -> WKWebExtensionContext? {
        contexts[id]
    }

    /// The installed extension whose context is `context`.
    func id(of context: WKWebExtensionContext) -> String? {
        contexts.first { $0.value === context }?.key
    }

    /// Loaded extensions that run in `controller`'s window (a private
    /// window: those allowed in private windows), in install order.
    func loadedContexts(for window: BrowserWindowController?) -> [(id: String, context: WKWebExtensionContext)] {
        store.records.compactMap { record in
            guard let context = contexts[record.id] else { return nil }
            if window?.kind.isPrivate == true, !context.hasAccessToPrivateData { return nil }
            return (record.id, context)
        }
    }

    /// Whether `manifest` says `incognito: "not_allowed"`.
    static func forbidsPrivate(_ webExtension: WKWebExtension) -> Bool {
        (webExtension.manifest["incognito"] as? String) == "not_allowed"
    }

    // MARK: - Loading

    /// Loads `id`'s package into the controller with its saved state
    /// (permissions, private access); a failure is kept in `loadErrors`.
    func load(_ id: String) async {
        guard contexts[id] == nil, let record = store.record(id: id), record.isEnabled else { return }
        do {
            let folder = store.folder(for: id)
            // A package from before this shim (or before P2) gets it now; one
            // that carries it is left alone (its stamp matches).
            let standIns = try await Task.detached {
                try BrowserExtensionShims.prepare(folder, fresh: false)
            }.value
            store.update(id: id) { Self.adopt(standIns: standIns, into: &$0) }
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            // The record may have changed (disabled, removed) meanwhile.
            guard contexts[id] == nil, let current = store.record(id: id), current.isEnabled else { return }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = id
            context.baseURL = URL(string: "\(Self.scheme)://\(id)/")!
            context.isInspectable = true
            context.inspectionName = webExtension.displayName ?? current.name
            restore(current, into: context)
            try controller.load(context)
            contexts[id] = context
            loadErrors[id] = nil
            if webExtension.hasBackgroundContent {
                // As Chrome does at install and launch: the worker registers
                // its listeners (context menus, tab events, rules) now, not
                // on the first event that would need it.
                Task { [weak self] in
                    do {
                        try await context.loadBackgroundContent()
                    } catch {
                        guard let self, self.contexts[id] === context else { return }
                        self.backgroundErrors[id] = Self.describe(error)
                        self.changes.notify()
                    }
                }
            }
            store.update(id: id) { record in
                record.name = webExtension.displayName ?? record.name
                record.version = webExtension.version ?? record.version
            }
            // What an update newly asked for runs only once the user allows it.
            let additions = Self.additions(
                requestedPermissions: webExtension.requestedPermissions.map(\.rawValue),
                requestedPatterns: webExtension.allRequestedMatchPatterns.map(\.string),
                record: current
            )
            pendingAdditions[id] = additions.isEmpty ? nil : additions
            askForAdditions(id)
        } catch {
            loadErrors[id] = Self.describe(error)
        }
        changes.notify()
    }

    func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        backgroundErrors[id] = nil
        if popup?.extensionID == id { closePopup() }
        eventPorts.removeValue(forKey: id)?.disconnect()
        nativeHost.detach(extensionID: id)
        for socket in sockets.values where socket.extensionID == id { socket.close() }
        try? controller.unload(context)
        changes.notify()
    }

    /// Shows the permission sheet (on the active window) for what an
    /// update newly asked for, once per launch: allowed, it is granted;
    /// refused, it is denied for good, as a refused request is. Without a
    /// window it waits for the next launch. The answer covers what the
    /// sheet listed only: an update landing while it is open adds items for
    /// the next sheet.
    private func askForAdditions(_ id: String) {
        guard let additions = pendingAdditions[id], !askedAdditions.contains(id),
              let context = contexts[id], manager?.activeController?.window != nil
        else { return }
        askedAdditions.insert(id)
        let name = context.webExtension.displayName ?? id
        prompt(context, tab: nil, lines: additions.lines, header: "“\(name)” was updated and now also wants to:") { [weak self] allowed in
            self?.decideAdditions(id, allowed: allowed, shown: additions)
        }
    }

    /// The user's answer about the additions a sheet showed (`shown`; nil:
    /// everything pending): those still pending are granted or denied and
    /// leave `pendingAdditions[id]`; the rest stay for the next sheet.
    func decideAdditions(_ id: String, allowed: Bool, shown: Additions? = nil) {
        guard let pending = pendingAdditions[id] else { return }
        let additions = shown.map(pending.intersection) ?? pending
        guard !additions.isEmpty else { return }
        let rest = pending.subtracting(additions)
        pendingAdditions[id] = rest.isEmpty ? nil : rest
        let status: WKWebExtensionContext.PermissionStatus = allowed ? .grantedExplicitly : .deniedExplicitly
        if let context = contexts[id] {
            for permission in additions.permissions {
                context.setPermissionStatus(status, for: WKWebExtension.Permission(rawValue: permission))
            }
            for string in additions.matchPatterns {
                if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                    context.setPermissionStatus(status, for: pattern)
                }
            }
            persist(context)
        } else {
            store.update(id: id) { record in
                if allowed {
                    Self.grant(additions, to: &record)
                } else {
                    for permission in additions.permissions { record.deniedPermissions[permission] = .distantFuture }
                    for pattern in additions.matchPatterns { record.deniedMatchPatterns[pattern] = .distantFuture }
                }
            }
        }
        changes.notify()
    }

    /// Records the stand-ins a package carries; the shim reaches the app
    /// through native messaging, so a shimmed extension is granted it
    /// (unless the user denied it).
    static func adopt(standIns: [String], into record: inout BrowserExtensionRecord) {
        record.standIns = standIns
        let permission = WKWebExtension.Permission.nativeMessaging.rawValue
        if !standIns.isEmpty, record.deniedPermissions[permission] == nil, record.grantedPermissions[permission] == nil {
            record.grantedPermissions[permission] = .distantFuture
        }
    }

    /// The record's saved grants and choices, applied before `load`.
    private func restore(_ record: BrowserExtensionRecord, into context: WKWebExtensionContext) {
        context.grantedPermissions = Dictionary(
            record.grantedPermissions.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        context.deniedPermissions = Dictionary(
            record.deniedPermissions.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        context.grantedPermissionMatchPatterns = Self.patterns(record.grantedMatchPatterns)
        context.deniedPermissionMatchPatterns = Self.patterns(record.deniedMatchPatterns)
        context.hasRequestedOptionalAccessToAllHosts = record.requestedOptionalAccessToAllHosts
        context.hasAccessToPrivateData = record.allowsPrivate && !Self.forbidsPrivate(context.webExtension)
    }

    private static func patterns(_ saved: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        var result: [WKWebExtension.MatchPattern: Date] = [:]
        for (string, date) in saved {
            if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                result[pattern] = date
            }
        }
        return result
    }

    /// Saves what WebKit now grants and denies `context`.
    func persist(_ context: WKWebExtensionContext) {
        guard let id = id(of: context) else { return }
        store.update(id: id) { record in
            record.grantedPermissions = Dictionary(
                context.grantedPermissions.map { ($0.key.rawValue, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            record.deniedPermissions = Dictionary(
                context.deniedPermissions.map { ($0.key.rawValue, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            record.grantedMatchPatterns = Dictionary(
                context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            record.deniedMatchPatterns = Dictionary(
                context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            record.requestedOptionalAccessToAllHosts = context.hasRequestedOptionalAccessToAllHosts
        }
    }

    private func observeContextNotifications() {
        let permissionNames: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        for name in permissionNames {
            notificationObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let context = notification.object as? WKWebExtensionContext
                MainActor.assumeIsolated {
                    guard let self, let context else { return }
                    self.persist(context)
                }
            })
        }
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.changes.notify()
            }
        })
    }

    // MARK: - Install

    /// Installs (or updates in place, keeping its settings) the extension
    /// `input` names: an id or Chrome Web Store link (downloaded and
    /// verified), or an unpacked folder (copied). Loads it when enabled.
    /// `confirm` (Settings ▸ Extensions) is asked before anything lands:
    /// a new extension's permission list, what an update newly asks for,
    /// or a replacement from another source. Without it (the CLI, the
    /// harness) a new extension is granted what it asks for, an update's
    /// new requests wait for the user's answer in the app, and a
    /// replacement is refused.
    @discardableResult
    func install(
        _ input: String,
        workingDirectory: URL? = nil,
        confirm: InstallConfirmation? = nil
    ) async throws -> BrowserExtensionRecord {
        guard let source = BrowserWebStore.source(for: input, workingDirectory: workingDirectory) else {
            throw InstallError.badInput(input)
        }
        switch source {
        case let .webStore(id):
            return try await installFromWebStore(id: id, confirm: confirm)
        case let .folder(url):
            return try await installFolder(url, confirm: confirm)
        }
    }

    func installFromWebStore(id: String, confirm: InstallConfirmation? = nil) async throws -> BrowserExtensionRecord {
        busy.insert(id)
        changes.notify()
        defer {
            busy.remove(id)
            changes.notify()
        }
        let package = try await BrowserWebStore.fetch(BrowserWebStore.downloadURL(id: id))
        let staged = store.stagingFolder()
        try await Self.unpackVerified(package, id: id, to: staged)
        return try await adopt(staged, id: id, source: .webStore, confirm: confirm)
    }

    /// Copies the folder first and takes the id from the copy's manifest
    /// (its `key`, else the folder's path), so the folder can't change
    /// between the id and the package.
    func installFolder(_ folder: URL, confirm: InstallConfirmation? = nil) async throws -> BrowserExtensionRecord {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              (try? BrowserExtensionArchive.checkManifest(data)) != nil
        else { throw InstallError.notAFolder(folder.path) }
        let staged = store.stagingFolder()
        let id = try await Task.detached {
            let manifest = try BrowserExtensionArchive.copyFolder(folder, to: staged)
            return BrowserExtensionID.id(forUnpackedManifest: manifest, folder: folder)
        }.value
        busy.insert(id)
        changes.notify()
        defer {
            busy.remove(id)
            changes.notify()
        }
        return try await adopt(staged, id: id, source: .folder(folder.path), confirm: confirm)
    }

    /// Parses and verifies a downloaded CRX3 as extension `id` (the Web
    /// Store's publisher proof required) and unpacks it into `staged`, off
    /// the main thread.
    nonisolated static func unpackVerified(_ package: Data, id: String, to staged: URL) async throws {
        try await Task.detached {
            let crx = try BrowserCRX3.parse(package)
            let archive = try crx.verify(
                expectedID: id,
                publisherKeyHashes: [BrowserCRX3.webStorePublisherKeyHash]
            )
            _ = try BrowserExtensionArchive.extract(archive, to: staged)
        }.value
    }

    /// Moves a checked package in as `id` with the stand-ins it asks for
    /// (`BrowserExtensionShims`, put in after the package's signatures or
    /// folder were checked), reads it with WebKit, saves its record and
    /// loads it. A new extension is granted what it asks for (installing
    /// is consent, after `confirm` showed the list, as in Chrome). An
    /// update keeps the user's grants and grants nothing new: what it
    /// newly asks for waits for the user (`confirm`, else the permission
    /// sheet once it loads). The same id from another source (a folder
    /// carrying a store extension's `key`, another folder) needs `confirm`
    /// and then starts over: a fresh record, its stored data deleted.
    private func adopt(
        _ staged: URL,
        id: String,
        source: BrowserExtensionRecord.Source,
        confirm: InstallConfirmation?
    ) async throws -> BrowserExtensionRecord {
        let webExtension: WKWebExtension
        let standIns: [String]
        do {
            standIns = try await Task.detached {
                try BrowserExtensionShims.prepare(staged, fresh: true)
            }.value
            webExtension = try await WKWebExtension(resourceBaseURL: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw InstallError.unreadable(Self.describe(error))
        }
        let permissions = webExtension.requestedPermissions.map(\.rawValue)
        let patterns = webExtension.allRequestedMatchPatterns.map(\.string)
        let existing = store.record(id: id)
        let replaced = existing.flatMap { $0.source == source ? nil : $0.source }
        var record: BrowserExtensionRecord
        var additions = Additions()
        if let existing, replaced == nil {
            record = existing
            additions = Self.applyUpdate(to: &record, requestedPermissions: permissions, requestedPatterns: patterns, standIns: standIns)
        } else {
            record = BrowserExtensionRecord(
                id: id,
                source: source,
                name: webExtension.displayName ?? id,
                version: webExtension.version ?? ""
            )
            Self.adopt(standIns: standIns, into: &record)
            Self.grantRequested(permissions: permissions, patterns: patterns, to: &record)
        }
        let review = InstallReview(
            id: id,
            name: webExtension.displayName ?? record.name,
            version: webExtension.version ?? record.version,
            icon: webExtension.icon(for: CGSize(width: 32, height: 32)),
            kind: replaced.map { .replace(installed: $0, new: source) } ?? (existing == nil ? .install : .update),
            lines: existing != nil && replaced == nil
                ? additions.lines
                : Self.permissionLines(of: webExtension)
        )
        if let replaced, confirm == nil {
            try? FileManager.default.removeItem(at: staged)
            throw InstallError.sourceChanged(id: id, installed: replaced, new: source)
        }
        var confirmed: Additions?
        if let confirm, review.kind != .update || !additions.isEmpty {
            guard await confirm(review) else {
                try? FileManager.default.removeItem(at: staged)
                throw InstallError.cancelled
            }
            confirmed = additions
        }
        // While the sheet was open the record may have changed (removed,
        // disabled, site access edited, installed from elsewhere): an
        // update starts from the record as it is now; a record that is gone
        // or now from another source cancels.
        let current = store.record(id: id)
        guard current?.source == existing?.source else {
            try? FileManager.default.removeItem(at: staged)
            throw InstallError.cancelled
        }
        if let current, replaced == nil {
            record = current
            let fresh = Self.applyUpdate(to: &record, requestedPermissions: permissions, requestedPatterns: patterns, standIns: standIns)
            if let confirmed {
                Self.grant(fresh.intersection(confirmed), to: &record)
            }
        }
        let wasLoaded = contexts[id] != nil
        unload(id)
        if replaced != nil {
            nativeHost.forget(id)
            await removeStoredData(of: id)
            // Removed while its data went: nothing to install over.
            guard store.record(id: id) != nil else {
                try? FileManager.default.removeItem(at: staged)
                throw InstallError.cancelled
            }
        }
        do {
            try store.installPackage(staged, id: id)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            if wasLoaded, replaced == nil { await load(id) }
            throw error
        }
        record.source = source
        record.name = webExtension.displayName ?? record.name
        record.version = webExtension.version ?? record.version
        store.save(record)
        pendingAdditions[id] = nil
        askedAdditions.remove(id)
        if record.isEnabled {
            await load(id)
        }
        changes.notify()
        return store.record(id: id) ?? record
    }

    /// What an extension may do, in Chrome's words, for the install sheet
    /// and the CLI.
    static func permissionLines(of webExtension: WKWebExtension) -> [String] {
        BrowserExtensionPermissionPrompt.describe(
            permissions: Array(webExtension.requestedPermissions),
            patterns: Array(webExtension.allRequestedMatchPatterns)
        )
    }

    /// A new record's grants: what the manifest requests (permissions
    /// always, sites while site access is "On all sites"), never what the
    /// user denied, never local files (`isFilePattern`).
    static func grantRequested(permissions: [String], patterns: [String], to record: inout BrowserExtensionRecord) {
        for permission in permissions where record.deniedPermissions[permission] == nil {
            record.grantedPermissions[permission] = record.grantedPermissions[permission] ?? .distantFuture
        }
        guard record.siteAccess == .allSites else { return }
        for pattern in patterns where record.deniedMatchPatterns[pattern] == nil && !isFilePattern(pattern) {
            record.grantedMatchPatterns[pattern] = record.grantedMatchPatterns[pattern] ?? .distantFuture
        }
    }

    /// An update's record: the stand-ins its copy carries and nothing
    /// newly granted. Returns what it asks for beyond what the user
    /// already granted or denied (`additions`).
    static func applyUpdate(
        to record: inout BrowserExtensionRecord,
        requestedPermissions: [String],
        requestedPatterns: [String],
        standIns: [String]
    ) -> Additions {
        adopt(standIns: standIns, into: &record)
        return additions(requestedPermissions: requestedPermissions, requestedPatterns: requestedPatterns, record: record)
    }

    /// What the manifest requests that the record neither grants nor
    /// denies: permissions, and sites while site access is "On all sites"
    /// (never local files). The shim's own `nativeMessaging` is already
    /// granted by `adopt(standIns:into:)`.
    static func additions(requestedPermissions: [String], requestedPatterns: [String], record: BrowserExtensionRecord) -> Additions {
        var additions = Additions()
        additions.permissions = Array(Set(requestedPermissions.filter {
            record.grantedPermissions[$0] == nil && record.deniedPermissions[$0] == nil
        })).sorted()
        if record.siteAccess == .allSites {
            additions.matchPatterns = Array(Set(requestedPatterns.filter {
                record.grantedMatchPatterns[$0] == nil && record.deniedMatchPatterns[$0] == nil && !isFilePattern($0)
            })).sorted()
        }
        return additions
    }

    static func grant(_ additions: Additions, to record: inout BrowserExtensionRecord) {
        for permission in additions.permissions { record.grantedPermissions[permission] = .distantFuture }
        for pattern in additions.matchPatterns { record.grantedMatchPatterns[pattern] = .distantFuture }
    }

    /// Local files are never granted automatically. WebKit (macOS 26)
    /// reports a `file:` page's permission as unknown even with
    /// `file:///*` granted and `<all_urls>` doesn't match `file:` there,
    /// so this keeps it so should that change.
    nonisolated static func isFilePattern(_ pattern: String) -> Bool {
        pattern.lowercased().hasPrefix("file:")
    }

    // MARK: - Settings

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        guard store.record(id: id) != nil else { throw InstallError.notInstalled(id) }
        store.update(id: id) { $0.isEnabled = enabled }
        if enabled {
            await load(id)
        } else {
            unload(id)
            nativeHost.forget(id)
            loadErrors[id] = nil
        }
        changes.notify()
    }

    func setAllowsPrivate(_ id: String, _ allowed: Bool) throws {
        guard store.record(id: id) != nil else { throw InstallError.notInstalled(id) }
        if allowed, let context = contexts[id], Self.forbidsPrivate(context.webExtension) {
            throw InstallError.privateNotAllowed
        }
        store.update(id: id) { $0.allowsPrivate = allowed }
        contexts[id]?.hasAccessToPrivateData = allowed
        changes.notify()
    }

    /// Settings ▸ Extensions ▸ Site access. "On all sites" grants every
    /// site the extension asks for; "On specific sites" only
    /// `allowedSites`; "When you click" none (the toolbar button grants the
    /// page it is clicked on).
    func setSiteAccess(_ id: String, _ access: BrowserExtensionRecord.SiteAccess) throws {
        guard store.record(id: id) != nil else { throw InstallError.notInstalled(id) }
        store.update(id: id) { $0.siteAccess = access }
        applySiteAccess(id)
    }

    /// Adds (or removes) `host` to the sites of "On specific sites" and
    /// switches to it.
    func setSite(_ id: String, host: String, allowed: Bool) throws {
        guard store.record(id: id) != nil else { throw InstallError.notInstalled(id) }
        let host = Self.siteHost(host)
        guard !host.isEmpty else { return }
        store.update(id: id) { record in
            record.siteAccess = .specificSites
            record.allowedSites.removeAll { $0 == host }
            if allowed { record.allowedSites.append(host) }
        }
        applySiteAccess(id)
    }

    /// `https://www.Example.com/a` → `example.com`.
    nonisolated static func siteHost(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = URL(string: trimmed)?.host ?? URL(string: "https://\(trimmed)")?.host ?? trimmed
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The match patterns for a host of "On specific sites".
    nonisolated static func sitePatterns(_ host: String) -> [String] {
        ["*://\(host)/*", "*://*.\(host)/*"]
    }

    /// Puts the record's site access into the loaded context (or, when not
    /// loaded, into the record's saved grants).
    private func applySiteAccess(_ id: String) {
        guard var record = store.record(id: id) else { return }
        let requested: [String]
        if let context = contexts[id] {
            requested = context.webExtension.allRequestedMatchPatterns.map(\.string)
        } else {
            requested = Array(record.grantedMatchPatterns.keys)
        }
        var granted: [String: Date] = [:]
        switch record.siteAccess {
        case .allSites:
            for pattern in requested where !Self.isFilePattern(pattern) { granted[pattern] = .distantFuture }
        case .specificSites:
            for host in record.allowedSites {
                for pattern in Self.sitePatterns(host) { granted[pattern] = .distantFuture }
            }
        case .onClick:
            break
        }
        if let context = contexts[id] {
            for pattern in context.grantedPermissionMatchPatterns.keys where granted[pattern.string] == nil {
                context.setPermissionStatus(.unknown, for: pattern)
            }
            for string in granted.keys {
                if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
            }
            if record.siteAccess != .allSites {
                context.hasRequestedOptionalAccessToAllHosts = false
            }
            persist(context)
        } else {
            record.grantedMatchPatterns = granted
            store.save(record)
        }
        changes.notify()
    }

    /// Removes `id`: unloads it, deletes what it stored and its package.
    func remove(_ id: String) async throws {
        guard store.record(id: id) != nil else { throw InstallError.notInstalled(id) }
        unload(id)
        nativeHost.forget(id)
        await removeStoredData(of: id)
        store.remove(id: id)
        loadErrors[id] = nil
        pendingAdditions[id] = nil
        changes.notify()
    }

    /// Deletes what extension `id` stored (storage, IndexedDB, …).
    private func removeStoredData(of id: String) async {
        let records = await controller.dataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes)
        let own = records.filter { $0.uniqueIdentifier == id }
        if !own.isEmpty {
            await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: own)
        }
    }

    /// Unloads every extension and deletes everything they stored (the
    /// harness's controller at the end of a run).
    func removeAllData() async {
        for id in Array(contexts.keys) { unload(id) }
        let records = await controller.dataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes)
        guard !records.isEmpty else { return }
        await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: records)
    }

    // MARK: - Updates

    /// Asks the Web Store for newer versions of the store extensions not
    /// checked for a day (all with `force`), then installs each after the
    /// same verification as an install. Returns the ids updated.
    @discardableResult
    func checkForUpdates(force: Bool) async -> [String] {
        let now = Date()
        let due = store.records.filter { record in
            guard record.source == .webStore, !busy.contains(record.id) else { return false }
            return force || record.lastUpdateCheck.map { now.timeIntervalSince($0) >= Self.updateInterval } ?? true
        }
        guard !due.isEmpty else { return [] }
        let answer: [String: BrowserWebStore.Update]
        do {
            let data = try await BrowserWebStore.fetch(BrowserWebStore.updateCheckURL(due.map { ($0.id, $0.version) }))
            answer = BrowserWebStore.parseUpdateCheck(data)
        } catch {
            return []
        }
        for record in due {
            store.update(id: record.id) { $0.lastUpdateCheck = now }
        }
        var updated: [String] = []
        for record in due {
            guard let update = answer[record.id],
                  BrowserWebStore.isNewer(update.version, than: record.version),
                  BrowserWebStore.isAllowedDownload(update.codebase)
            else { continue }
            busy.insert(record.id)
            changes.notify()
            do {
                let package = try await BrowserWebStore.fetch(update.codebase)
                if let expected = update.sha256?.lowercased(), !expected.isEmpty,
                   Self.sha256Hex(package) != expected
                {
                    throw BrowserCRX3.Failure.badSignature("package hash")
                }
                let staged = store.stagingFolder()
                try await Self.unpackVerified(package, id: record.id, to: staged)
                busy.remove(record.id)
                _ = try await adopt(staged, id: record.id, source: .webStore, confirm: nil)
                updated.append(record.id)
            } catch {
                busy.remove(record.id)
                loadErrors[record.id] = contexts[record.id] == nil ? "Update failed: \(Self.describe(error))" : nil
            }
            changes.notify()
        }
        return updated
    }

    /// SHA-256 as lowercase hex, for the update check's `hash_sha256`.
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ error: Error) -> String {
        error.localizedDescription
    }

    // MARK: - Commands

    /// Runs the extension shortcut `event` names (not one of the app's own
    /// shortcuts) in `window`'s extensions. True when one ran.
    func performCommand(for event: NSEvent, in window: BrowserWindowController) -> Bool {
        guard event.type == .keyDown else { return false }
        if let shortcut = BrowserShortcut(event: event),
           window.settingsStore.settings.keymap.command(for: shortcut) != nil
        {
            return false
        }
        for (_, context) in loadedContexts(for: window) where context.command(for: event) != nil {
            if context.performCommand(for: event) { return true }
        }
        return false
    }

    /// Every loaded extension command `window` offers (menu and Command
    /// Bar rows), in install order.
    func commands(for window: BrowserWindowController?) -> [(id: String, name: String, command: WKWebExtension.Command)] {
        loadedContexts(for: window).flatMap { id, context in
            let name = context.webExtension.displayShortName ?? context.webExtension.displayName ?? id
            return context.commands.map { (id, name, $0) }
        }
    }

    func performCommand(extensionID: String, commandID: String) {
        guard let context = contexts[extensionID],
              let command = context.commands.first(where: { $0.id == commandID })
        else { return }
        context.performCommand(command)
    }

    /// The shortcut a command shows, from its activation key and modifiers.
    static func shortcutText(_ command: WKWebExtension.Command) -> String {
        guard let key = command.activationKey, !key.isEmpty else { return "" }
        let flags = command.modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }
}

extension BrowserExtensions.InstallError: LocalizedError {
    var errorDescription: String? { description }
}
