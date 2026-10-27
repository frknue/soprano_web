import AppKit
import WebKit

/// The window's side of extensions: the toolbar's action buttons for the
/// selected tab, a click (the action, or its popup), each button's menu,
/// the Command Bar's extension rows and extension pages in tabs (they need
/// the extension's own web view configuration).
extension BrowserWindowController {
    var extensions: BrowserExtensions { manager.extensions }

    /// One button per extension this window runs (a private window: only
    /// those allowed in private windows), showing its action for the page
    /// shown (the Peek's while one is open).
    func updateExtensionButtons() {
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        let items = extensions.loadedContexts(for: self).map { id, context -> BrowserExtensionToolbarItem in
            let action = context.action(for: tab)
            let name = context.webExtension.displayName ?? id
            let label = action?.label ?? ""
            return BrowserExtensionToolbarItem(
                id: id,
                icon: action?.icon(for: CGSize(width: 16, height: 16))
                    ?? context.webExtension.actionIcon(for: CGSize(width: 16, height: 16))
                    ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)),
                label: label.isEmpty ? name : label,
                badge: action?.badgeText ?? "",
                isEnabled: action?.isEnabled ?? true
            )
        }
        toolbar.setExtensionButtons(items)
    }

    /// A click on an extension's button: its action for the page shown
    /// (the Peek's while one is open; a user gesture, so `activeTab`
    /// grants that page); WebKit fires `action.onClicked` or asks for the
    /// popup.
    func performExtensionAction(_ id: String) {
        guard let context = extensions.context(id: id) else { return }
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        context.performAction(for: tab)
    }

    /// The button's menu: the action's own items, the options page,
    /// Settings ▸ Extensions and Remove.
    func extensionMenu(_ id: String) -> NSMenu? {
        guard let context = extensions.context(id: id) else { return nil }
        let menu = NSMenu()
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        let title = NSMenuItem(title: context.webExtension.displayName ?? id, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let own = context.action(for: tab)?.menuItems ?? []
        if !own.isEmpty {
            menu.addItem(.separator())
            own.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        if let options = context.optionsPageURL {
            menu.addItem(BrowserClosureMenuItem(title: "Options") { [weak self] in
                self?.extensions.openExtensionPage(options, for: context)
            })
        }
        menu.addItem(BrowserClosureMenuItem(title: "Manage Extensions…") { [weak self] in
            self?.manager.showSettings(page: .extensions)
        })
        return menu
    }

    /// The Command Bar's extension rows: each extension's commands
    /// ("uBlock Origin Lite: Open the dashboard") and its toolbar action.
    func extensionCommandBarActions() -> [BrowserCommandBarInput.Action] {
        var actions: [BrowserCommandBarInput.Action] = []
        for (id, context) in extensions.loadedContexts(for: self) {
            let name = context.webExtension.displayName ?? id
            actions.append(BrowserCommandBarInput.Action(
                target: .extensionAction(id),
                title: name,
                synonyms: ["extension", context.webExtension.displayShortName ?? ""].filter { !$0.isEmpty },
                shortcut: "",
                symbol: "puzzlepiece.extension"
            ))
            for command in context.commands where command.id != "_execute_action" && !command.title.isEmpty {
                actions.append(BrowserCommandBarInput.Action(
                    target: .extensionCommand(extensionID: id, commandID: command.id),
                    title: "\(name): \(command.title)",
                    synonyms: ["extension"],
                    shortcut: BrowserExtensions.shortcutText(command),
                    symbol: "puzzlepiece.extension"
                ))
            }
        }
        return actions
    }

    // MARK: Extension pages in tabs

    /// The extension whose page `url` is (`chrome-extension://<id>/…`),
    /// when it is loaded.
    func extensionContext(for url: URL?) -> WKWebExtensionContext? {
        guard let url, url.scheme?.lowercased() == BrowserExtensions.scheme else { return nil }
        return extensions.controller.extensionContext(for: url)
    }

    /// Whether `tab`'s web view can show `url`: an extension page needs a
    /// web view made from its extension's configuration, and a web page
    /// (http, https, file) one made from the tab's own. Other addresses
    /// (about:, data:, the start page) load in either.
    func webViewFits(_ tab: BrowserTab, url: URL) -> Bool {
        if let context = extensionContext(for: url) {
            return tab.webView.extensionID == extensions.id(of: context)
        }
        guard tab.webView.extensionID != nil else { return true }
        return !["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The navigation gate for pages, in `decidePolicyFor` before any tab
    /// opens or swaps its web view. A navigation that leaves its frame (a
    /// main-frame load, or a link click that opens a tab, a Peek or a split
    /// pane, as `handleLinkNavigation` decides it):
    /// - into an extension page from a web view that isn't that
    ///   extension's is allowed only when that extension's own frame
    ///   started it (`mayShowPage`): the swap loads the page app-side,
    ///   past WebKit's `web_accessible_resources` check, so a web page may
    ///   never ask for it (frames inside a page still load through WebKit);
    /// - out of an extension page (its page in a tab) goes through the
    ///   extensions' load gate (`pageLoad`): never a local file.
    func allowsExtensionNavigation(_ navigationAction: WKNavigationAction, to url: URL, in tab: BrowserTab) -> Bool {
        let opensTab = navigationAction.navigationType == .linkActivated
            && BrowserLinkDisposition.disposition(
                modifierFlags: navigationAction.modifierFlags,
                buttonNumber: navigationAction.buttonNumber,
                origin: tab.origin,
                pageURL: tab.webView.url,
                linkURL: url,
                targetsMainFrame: navigationAction.targetFrame?.isMainFrame ?? true
            ) != .currentTab
        guard navigationAction.targetFrame?.isMainFrame != false || opensTab else { return true }
        if let context = extensionContext(for: url), let id = extensions.id(of: context), tab.webView.extensionID != id || opensTab {
            let origin = (navigationAction.value(forKey: "sourceFrame") as? WKFrameInfo)?.securityOrigin
            return BrowserExtensions.mayShowPage(
                ofExtension: id,
                sourceScheme: origin?.protocol,
                sourceHost: origin?.host,
                isPrivate: kind.isPrivate,
                hasPrivateAccess: context.hasAccessToPrivateData
            )
        }
        if let id = tab.webView.extensionID, !webViewFits(tab, url: url) || opensTab {
            return BrowserExtensions.pageLoad(url, extensionID: id) != .refuse
        }
        return true
    }
}

/// A menu item that runs a closure.
final class BrowserClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func runClosure() {
        run()
    }
}
