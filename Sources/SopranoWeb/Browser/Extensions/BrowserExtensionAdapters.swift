import AppKit
import WebKit

/// A real tab as extensions see it (`chrome.tabs`): one adapter per live
/// `BrowserTab` for its whole life, wherever it moves. Its window is the
/// one holding it now; its index counts every tab of that window, of every
/// Space (one tab list per window).
@MainActor
final class BrowserExtensionTab: NSObject, WKWebExtensionTab {
    let tabID: UUID
    private(set) weak var tab: BrowserTab?
    private unowned let extensions: BrowserExtensions
    /// Where the tab was when it left a window, until it joins the next one
    /// (a move, announced as `didMoveTab`).
    var departure: (window: BrowserExtensionWindow, index: Int)?

    init(tab: BrowserTab, extensions: BrowserExtensions) {
        tabID = tab.id
        self.tab = tab
        self.extensions = extensions
    }

    private var location: (window: BrowserWindowController, tab: BrowserTab)? {
        extensions.manager?.tab(id: tabID)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        location.map { extensions.windowAdapter(for: $0.window) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let (window, tab) = location else { return NSNotFound }
        return window.tabs.firstIndex { $0 === tab } ?? NSNotFound
    }

    /// The tab whose page opened this one (a link with a target, ⌘-click,
    /// `window.open`): Chrome's `openerTabId`, which the webNavigation
    /// stand-in reports as `onCreatedNavigationTarget`.
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let openerID = tab?.links.openerID, let opener = extensions.manager?.tab(id: openerID)?.tab else { return nil }
        return extensions.tabAdapter(for: opener)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.displayTitle
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab.map { $0.origin != .today } ?? false
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingAudio ?? false
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        tab?.isMuted ?? false
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location, tab.isMuted != muted {
            window.toggleMute(tab)
        }
        completionHandler(nil)
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(tab?.webView.pageZoom ?? 1)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab {
            tab.zoom = zoomFactor
            tab.webView.pageZoom = zoomFactor
        }
        completionHandler(nil)
    }

    /// A tab not loaded yet (restored, asleep) reports the address it will load.
    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.item.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let tab, tab.webView.isLoading else { return nil }
        return tab.pendingURL.flatMap(URL.init(string:))
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.webView.isLoading ?? false)
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, (any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(nil, nil)
            return
        }
        tab.webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    /// `tabs.update({ url })`, through the extensions' load gate
    /// (`BrowserExtensions.pageLoad`): another app's link asks first, a
    /// local file or another extension's page is refused.
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let (window, tab) = location else {
            completionHandler(nil)
            return
        }
        switch BrowserExtensions.pageLoad(url, extensionID: window.extensions.id(of: context)) {
        case .load:
            window.navigate(tab, to: url)
        case .external:
            window.openExternalLink(url, fromExtension: context.webExtension.displayName ?? "An extension", in: tab)
        case .refuse:
            completionHandler(BrowserExtensions.refusal("Extensions can't open \(url.scheme ?? "this") addresses."))
            return
        }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location {
            if fromOrigin, !tab.isStartPage, tab.failedURL == nil {
                tab.pendingURL = tab.webView.url?.absoluteString
                tab.webView.reloadFromOrigin()
            } else {
                window.reload(tab)
            }
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location { window.goBack(tab) }
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location { window.goForward(tab) }
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location {
            window.selectTab(id: tab.id, focus: true)
            extensions.manager?.present(window)
        }
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let (window, tab) = location else { return false }
        return window.selectedTab === tab
    }

    /// One selected tab per window: selecting activates it; deselecting
    /// leaves it.
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if selected, let (window, tab) = location {
            window.selectTab(id: tab.id, focus: true)
        }
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let (window, tab) = location, let copy = window.duplicateTab(id: tab.id) else {
            completionHandler(nil, nil)
            return
        }
        completionHandler(extensions.tabAdapter(for: copy), nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let (window, tab) = location {
            window.closeTab(id: tab.id)
        }
        completionHandler(nil)
    }

    /// `activeTab`: clicking an extension's button or running its command
    /// grants it the page.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

/// A real window as extensions see it (`chrome.windows`): every tab of
/// every Space in window order; a private window says so.
@MainActor
final class BrowserExtensionWindow: NSObject, WKWebExtensionWindow {
    let windowID: UUID
    private(set) weak var controller: BrowserWindowController?
    private unowned let extensions: BrowserExtensions

    init(controller: BrowserWindowController, extensions: BrowserExtensions) {
        windowID = controller.id
        self.controller = controller
        self.extensions = extensions
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        controller?.tabs.map { extensions.tabAdapter(for: $0) } ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        controller?.selectedTab.map { extensions.tabAdapter(for: $0) }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        controller?.role.isCompact == true ? .popup : .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = controller?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let window = controller?.window {
            switch state {
            case .minimized:
                window.miniaturize(nil)
            case .fullscreen:
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            case .maximized:
                if window.isMiniaturized { window.deminiaturize(nil) }
                if !window.isZoomed { window.zoom(nil) }
            case .normal:
                if window.isMiniaturized { window.deminiaturize(nil) }
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            @unknown default:
                break
            }
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        controller?.kind.isPrivate ?? false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        controller?.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        controller?.window?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        controller?.window?.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let controller, let manager = extensions.manager {
            manager.present(controller)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let controller, let manager = extensions.manager {
            manager.closeWindow(controller)
        }
        completionHandler(nil)
    }
}

// MARK: - Lifecycle

/// The window and tab life the controller announces to every loaded
/// extension. Windows call these from the places that open, bind, move,
/// select and close tabs; WebKit leaves out what a context may not see
/// (private windows without private access).
extension BrowserExtensions {
    func tabAdapter(for tab: BrowserTab) -> BrowserExtensionTab {
        if let adapter = tabAdapters[tab.id], adapter.tab === tab {
            return adapter
        }
        let adapter = BrowserExtensionTab(tab: tab, extensions: self)
        tabAdapters[tab.id] = adapter
        return adapter
    }

    func windowAdapter(for controller: BrowserWindowController) -> BrowserExtensionWindow {
        if let adapter = windowAdapters[controller.id], adapter.controller === controller {
            return adapter
        }
        let adapter = BrowserExtensionWindow(controller: controller, extensions: self)
        windowAdapters[controller.id] = adapter
        return adapter
    }

    /// A new window (before its tabs join it).
    func windowOpened(_ controller: BrowserWindowController) {
        self.controller.didOpenWindow(windowAdapter(for: controller))
    }

    /// The window is closing: each of its tabs closes with it, then the
    /// window.
    func windowClosing(_ controller: BrowserWindowController) {
        guard let window = windowAdapters[controller.id] else { return }
        for tab in controller.tabs {
            if let adapter = tabAdapters.removeValue(forKey: tab.id) {
                self.controller.didCloseTab(adapter, windowIsClosing: true)
            }
        }
        self.controller.didCloseWindow(window)
        windowAdapters[controller.id] = nil
        if self.manager?.keyController == nil {
            self.controller.didFocusWindow(nil)
        }
    }

    func windowFocused(_ controller: BrowserWindowController) {
        self.controller.didFocusWindow(windowAdapter(for: controller))
    }

    /// `tab` joined `controller`: a tab seen for the first time opened;
    /// one that left another window moved.
    func tabAttached(_ tab: BrowserTab, to controller: BrowserWindowController) {
        let known = tabAdapters[tab.id]?.tab === tab
        let adapter = tabAdapter(for: tab)
        _ = windowAdapter(for: controller)
        if let departure = adapter.departure {
            adapter.departure = nil
            self.controller.didMoveTab(adapter, from: departure.index, in: departure.window)
        } else if !known {
            self.controller.didOpenTab(adapter)
        }
    }

    /// `tab` left `controller` at `index` (moving, or about to close).
    func tabDetached(_ tab: BrowserTab, from controller: BrowserWindowController, index: Int) {
        guard let adapter = tabAdapters[tab.id], adapter.tab === tab else { return }
        adapter.departure = (windowAdapter(for: controller), index)
    }

    /// The tab is gone for good.
    func tabClosed(_ tab: BrowserTab) {
        guard let adapter = tabAdapters[tab.id], adapter.tab === tab else { return }
        tabAdapters[tab.id] = nil
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        controller.didActivateTab(
            tabAdapter(for: tab),
            previousActiveTab: previous.flatMap { tabAdapters[$0.id] }
        )
    }

    func tabChanged(_ tab: BrowserTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard let adapter = tabAdapters[tab.id], adapter.tab === tab else { return }
        controller.didChangeTabProperties(properties, for: adapter)
    }
}
