import AppKit
import WebKit

/// What extensions ask the app for: the open windows, new tabs and
/// windows, the options page, permission prompts, action popups and
/// native messages. Every selector is checked in
/// `BrowserDelegateSelectorTests`.
extension BrowserExtensions: WKWebExtensionControllerDelegate {
    /// The windows `context` may see, the focused one first.
    func visibleWindows(for context: WKWebExtensionContext) -> [BrowserWindowController] {
        guard let manager else { return [] }
        return manager.mostRecentlyActiveFirst { window in
            context.hasAccessToPrivateData || !window.kind.isPrivate
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        visibleWindows(for: extensionContext).map { windowAdapter(for: $0) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let key = manager?.keyController,
              extensionContext.hasAccessToPrivateData || !key.kind.isPrivate
        else { return nil }
        return windowAdapter(for: key)
    }

    /// `tabs.create`: in the given window, else the most recent window with
    /// tabs the extension may see (a new normal window when there is none).
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let manager else {
            completionHandler(nil, nil)
            return
        }
        if let url = configuration.url, Self.pageLoad(url, extensionID: id(of: extensionContext)) != .load {
            completionHandler(nil, Self.refusal("Extensions can't open \(url.scheme ?? "this") addresses."))
            return
        }
        let requested = (configuration.window as? BrowserExtensionWindow)?.controller
        let target = requested.flatMap { $0.role == .normal ? $0 : nil }
            ?? manager.mostRecentlyActive { $0.role == .normal && (extensionContext.hasAccessToPrivateData || !$0.kind.isPrivate) }
        guard let target else {
            let window = manager.newWindow(url: configuration.url?.absoluteString)
            completionHandler(window.selectedTab.map { tabAdapter(for: $0) }, nil)
            return
        }
        let tab = target.newTab(url: configuration.url?.absoluteString, select: configuration.shouldBeActive)
        if configuration.index != NSNotFound, configuration.index >= 0,
           let visible = target.visibleTabs.firstIndex(where: { $0 === tab })
        {
            let index = min(configuration.index, target.visibleTabs.count - 1)
            if index != visible { target.moveTab(id: tab.id, toIndex: index) }
        }
        if configuration.shouldBeActive {
            target.revealWindowIfNeeded()
        }
        completionHandler(tabAdapter(for: tab), nil)
    }

    /// `windows.create`: a normal window in the active Space (a private
    /// one when asked and allowed) with the URLs, and the given tabs moved
    /// into it.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let manager else {
            completionHandler(nil, nil)
            return
        }
        if configuration.shouldBePrivate, !extensionContext.hasAccessToPrivateData {
            completionHandler(nil, Self.refusal("The extension isn't allowed in private windows."))
            return
        }
        let urls = configuration.tabURLs.filter { Self.pageLoad($0, extensionID: id(of: extensionContext)) == .load }
        let moving = configuration.tabs.compactMap { ($0 as? BrowserExtensionTab)?.tab }
        let window: BrowserWindowController
        if urls.isEmpty, let first = moving.first, !configuration.shouldBePrivate,
           let source = manager.tab(id: first.id)?.window,
           let created = manager.moveTabToNewWindow(first, from: source, raise: configuration.shouldBeFocused)
        {
            window = created
        } else if configuration.shouldBePrivate {
            window = manager.newPrivateWindow(url: urls.first?.absoluteString)
        } else {
            window = manager.newWindow(url: urls.first?.absoluteString)
        }
        for url in urls.dropFirst() {
            window.newTab(url: url.absoluteString, select: false)
        }
        for tab in moving where !window.tabs.contains(where: { $0 === tab }) {
            if let source = manager.tab(id: tab.id)?.window, manager.canMoveTab(tab, from: source, to: window) {
                manager.moveTab(tab, from: source, to: window, at: nil, select: false)
            }
        }
        let frame = configuration.frame
        if let nsWindow = window.window, !frame.origin.x.isNaN, !frame.origin.y.isNaN,
           !frame.size.width.isNaN, !frame.size.height.isNaN, frame.width > 0, frame.height > 0
        {
            nsWindow.setFrame(frame, display: true)
        }
        completionHandler(windowAdapter(for: window), nil)
    }

    /// `runtime.openOptionsPage`: the options page in a new tab.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL else {
            completionHandler(Self.refusal("The extension has no options page."))
            return
        }
        openExtensionPage(url, for: extensionContext)
        completionHandler(nil)
    }

    /// Opens a page an extension asks for (its options page, a link or
    /// `window.open` in its popup) in a new selected tab of the most recent
    /// window the extension may see, through `pageLoad`: another app's
    /// link asks first (`openExternalLink(_:fromExtension:in:)`); local
    /// files, scripts and other extensions' pages are refused.
    func openExtensionPage(_ url: URL, for context: WKWebExtensionContext) {
        guard let manager else { return }
        let decision = Self.pageLoad(url, extensionID: id(of: context))
        guard decision != .refuse else { return }
        let target = manager.mostRecentlyActive(where: {
            $0.role == .normal && (context.hasAccessToPrivateData || !$0.kind.isPrivate)
        })
        if decision == .external {
            guard let target, let tab = target.selectedTab else { return }
            target.openExternalLink(url, fromExtension: context.webExtension.displayName ?? "An extension", in: tab)
            return
        }
        if let target {
            target.newTab(url: url.absoluteString)
            manager.present(target)
        } else {
            manager.newWindow(url: url.absoluteString)
        }
    }

    // MARK: Permission prompts

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let lines = permissions.map { BrowserExtensionPermissionPrompt.describe($0) }.sorted()
        prompt(extensionContext, tab: tab, lines: lines) { [weak self] allowed in
            completionHandler(allowed ? permissions : [], nil)
            guard !allowed else { return }
            for permission in permissions {
                extensionContext.setPermissionStatus(.deniedExplicitly, for: permission)
            }
            self?.persist(extensionContext)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let lines = Set(urls.compactMap { $0.host }).sorted().map { "Read and change your data on \($0)" }
        prompt(extensionContext, tab: tab, lines: lines.isEmpty ? ["Read and change data on these pages"] : lines) { [weak self] allowed in
            completionHandler(allowed ? urls : [], nil)
            guard !allowed else { return }
            for url in urls {
                extensionContext.setPermissionStatus(.deniedExplicitly, for: url)
            }
            self?.persist(extensionContext)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        // Local files are never granted (`isFilePattern`).
        let grantable = matchPatterns.filter { !Self.isFilePattern($0.string) }
        let lines = BrowserExtensionPermissionPrompt.describe(permissions: [], patterns: Array(grantable))
        guard !grantable.isEmpty else {
            completionHandler([], nil)
            return
        }
        prompt(extensionContext, tab: tab, lines: lines) { [weak self] allowed in
            completionHandler(allowed ? grantable : [], nil)
            guard !allowed else { return }
            for pattern in matchPatterns {
                extensionContext.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
            self?.persist(extensionContext)
        }
    }

    // MARK: Action

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        actionChanges.notify()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(presentPopup(for: action, context: context))
    }

    // MARK: Native messaging

    /// `runtime.sendNativeMessage`: the host registered for the application
    /// identifier, when it answers this extension (its allowlist); else
    /// Chrome's "host not found".
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let handler = Self.allowedNativeHost(nativeHosts, application: applicationIdentifier, extensionID: id(of: extensionContext))?.message else {
            replyHandler(nil, Self.refusal("Specified native messaging host not found."))
            return
        }
        let box = BrowserExtensionMessage(value: message)
        Task { @MainActor in
            do {
                replyHandler(try await handler(box.value, extensionContext), nil)
            } catch {
                replyHandler(nil, error)
            }
        }
    }

    /// `runtime.connectNative`: the port handler of the host registered for
    /// the application identifier, when it answers this extension. Else the
    /// port opens and closes at once with Chrome's "host not found"
    /// (`onDisconnect` and `runtime.lastError`), as Chrome answers an app
    /// that isn't installed: a refused connect is a thrown error in WebKit,
    /// which an extension probing for its desktop app (1Password) doesn't
    /// expect.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let handler = Self.allowedNativeHost(nativeHosts, application: port.applicationIdentifier, extensionID: id(of: extensionContext))?.port else {
            completionHandler(nil)
            DispatchQueue.main.async {
                port.disconnect(throwing: Self.refusal("Specified native messaging host not found."))
            }
            return
        }
        do {
            try handler(port, extensionContext)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    // MARK: Helpers

    /// The native host `application` names, when its allowlist has the
    /// extension (an unknown context, `nil`, never gets one).
    static func allowedNativeHost(_ hosts: [String: NativeHost], application: String?, extensionID: String?) -> NativeHost? {
        guard let extensionID, let host = hosts[application ?? ""], host.allows(extensionID) else { return nil }
        return host
    }

    /// What becomes of an address an extension asks to load — `tabs.create`,
    /// `tabs.update`, `windows.create`, a link or `window.open` in its popup
    /// or options page, its page in a tab navigating away: web pages,
    /// `about:`, `data:` and its own pages load; another app's link
    /// (`zoommtg:`, `smb:`) asks first, as a page's link does; local files,
    /// scripts, blobs, the start page and other extensions' pages never.
    enum PageLoad: Equatable, Sendable {
        case load
        case external
        case refuse
    }

    static func pageLoad(_ url: URL, extensionID: String?) -> PageLoad {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https", "about", "data":
            return .load
        case Self.scheme:
            guard let extensionID, url.host?.lowercased() == extensionID else { return .refuse }
            return .load
        case "", "file", "javascript", "vbscript", "blob", "filesystem", BrowserStartPageSchemeHandler.scheme:
            return .refuse
        default:
            return .external
        }
    }

    /// Whether a navigation a page started may show extension `id`'s page
    /// in that extension's own web view (the tab's is swapped app-side, so
    /// WebKit's `web_accessible_resources` check never runs): only when
    /// one of that extension's own frames started it, and in a private
    /// window only when the extension is allowed there. A web page never
    /// opens an extension page this way.
    static func mayShowPage(
        ofExtension id: String,
        sourceScheme: String?,
        sourceHost: String?,
        isPrivate: Bool,
        hasPrivateAccess: Bool
    ) -> Bool {
        guard sourceScheme?.lowercased() == Self.scheme, sourceHost?.lowercased() == id else { return false }
        return !isPrivate || hasPrivateAccess
    }

    static func refusal(_ message: String) -> NSError {
        NSError(domain: "SopranoWebExtensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// A message from an extension's `runtime.sendNativeMessage`: a JSON
/// value WebKit hands over on the main actor.
struct BrowserExtensionMessage: @unchecked Sendable {
    let value: Any
}
