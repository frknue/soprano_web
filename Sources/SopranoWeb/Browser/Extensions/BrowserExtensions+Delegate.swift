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
        if let url = configuration.url, !Self.mayOpen(url) {
            completionHandler(nil, Self.refusal("Extensions can't open \(url.scheme ?? "this") addresses."))
            return
        }
        let requested = (configuration.window as? BrowserExtensionWindow)?.controller
        let target = requested.flatMap { $0.isPopup ? nil : $0 }
            ?? manager.mostRecentlyActive { !$0.isPopup && (extensionContext.hasAccessToPrivateData || !$0.kind.isPrivate) }
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
        let urls = configuration.tabURLs.filter(Self.mayOpen)
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

    /// Opens an extension page (options) in a new selected tab of the most
    /// recent window the extension may see.
    func openExtensionPage(_ url: URL, for context: WKWebExtensionContext) {
        guard let manager else { return }
        if let target = manager.mostRecentlyActive(where: {
            !$0.isPopup && (context.hasAccessToPrivateData || !$0.kind.isPrivate)
        }) {
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
        let lines = matchPatterns.map { pattern in
            pattern.matchesAllHosts || pattern.matchesAllURLs
                ? "Read and change your data on all websites"
                : "Read and change your data on \(pattern.host ?? pattern.string)"
        }
        prompt(extensionContext, tab: tab, lines: Array(Set(lines)).sorted()) { [weak self] allowed in
            completionHandler(allowed ? matchPatterns : [], nil)
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

    /// `runtime.sendNativeMessage`: the handler registered for the
    /// application identifier (the stand-ins'); none is Chrome's "host not
    /// found".
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard let handler = nativeMessageHandlers[applicationIdentifier ?? ""] else {
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

    /// `runtime.connectNative`: the port handler registered for the
    /// application identifier. With none, the port opens and closes at
    /// once with Chrome's "host not found" (`onDisconnect` and
    /// `runtime.lastError`), as Chrome answers an app that isn't installed:
    /// a refused connect is a thrown error in WebKit, which an extension
    /// probing for its desktop app (1Password) doesn't expect.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let handler = nativePortHandlers[port.applicationIdentifier ?? ""] else {
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

    /// Extensions open web pages and their own pages, never `javascript:`
    /// or local files.
    static func mayOpen(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return ["http", "https", "about", "data", Self.scheme].contains(scheme)
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
