import AppKit
import WebKit

/// One row of the toolbar's Extensions menu: an extension's action for the
/// page shown.
struct BrowserExtensionMenuRow: Equatable {
    var id: String
    var icon: NSImage?
    var label: String
    /// Empty: no badge.
    var badge: String
    var isEnabled: Bool
}

/// The window's side of extensions: the toolbar's Extensions button and
/// its menu (each extension's action for the page shown, its own menu
/// items and options), the Command Bar's extension rows and extension
/// pages in tabs (they need the extension's own web view configuration).
extension BrowserWindowController {
    var extensions: BrowserExtensions { manager.extensions }

    /// The Extensions button shows while an extension runs in this window
    /// (a private window: one allowed in private windows).
    func updateExtensionsButton() {
        toolbar.setShowsExtensions(!extensions.loadedContexts(for: self).isEmpty)
    }

    /// Each extension's action for the page shown (the Peek's while one is
    /// open): icon, label, badge and whether it is enabled there.
    func extensionMenuRows() -> [BrowserExtensionMenuRow] {
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        let size = CGSize(width: 16, height: 16)
        return extensions.loadedContexts(for: self).map { id, context in
            let action = context.action(for: tab)
            let name = context.webExtension.displayName ?? id
            let label = action?.label ?? ""
            return BrowserExtensionMenuRow(
                id: id,
                icon: action?.icon(for: size)
                    ?? context.webExtension.actionIcon(for: size)
                    ?? context.webExtension.icon(for: size),
                label: label.isEmpty ? name : label,
                badge: action?.badgeText ?? "",
                isEnabled: action?.isEnabled ?? true
            )
        }
    }

    /// The Extensions button's menu: a row per extension (its action),
    /// then each extension with menu items of its own or an options page
    /// as a submenu, then Manage Extensions….
    func extensionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rows = extensionMenuRows()
        for row in rows {
            let item = BrowserClosureMenuItem(title: row.label) { [weak self] in
                self?.performExtensionAction(row.id)
            }
            item.representedObject = row.id
            if let icon = row.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            } else {
                item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            }
            if !row.badge.isEmpty { item.badge = NSMenuItemBadge(string: row.badge) }
            item.isEnabled = row.isEnabled
            menu.addItem(item)
        }
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        let labels = Dictionary(rows.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let settings = extensions.loadedContexts(for: self).compactMap { id, context -> NSMenuItem? in
            let submenu = NSMenu()
            context.action(for: tab)?.menuItems.forEach(submenu.addItem)
            if let options = context.optionsPageURL {
                if !submenu.items.isEmpty { submenu.addItem(.separator()) }
                submenu.addItem(BrowserClosureMenuItem(title: "Options") { [weak self] in
                    self?.extensions.openExtensionPage(options, for: context)
                })
            }
            guard !submenu.items.isEmpty else { return nil }
            let item = NSMenuItem(title: labels[id] ?? context.webExtension.displayName ?? id, action: nil, keyEquivalent: "")
            item.submenu = submenu
            return item
        }
        if !settings.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Options"))
            settings.forEach(menu.addItem)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(BrowserClosureMenuItem(title: "Manage Extensions…") { [weak self] in
            self?.manager.showSettings(page: .extensions)
        })
        return menu
    }

    /// Chooses extension `id`'s row in a fresh Extensions menu, through the
    /// item's own target and action as a click sends them (the harness and
    /// `browser extension action`). False when the menu has no enabled row
    /// for it.
    @discardableResult
    func chooseExtensionMenuRow(_ id: String) -> Bool {
        let menu = extensionsMenu()
        guard let item = menu.items.first(where: { $0.representedObject as? String == id }), item.isEnabled,
              let action = item.action
        else { return false }
        return withExtendedLifetime(menu) { NSApp.sendAction(action, to: item.target, from: item) }
    }

    func showExtensionsMenu(from anchor: NSView) {
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        extensionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }

    /// A click on an extension's row: its action for the page shown (the
    /// Peek's while one is open; a user gesture, so `activeTab` grants that
    /// page); WebKit fires `action.onClicked` or asks for the popup, which
    /// hangs from the Extensions button.
    func performExtensionAction(_ id: String) {
        guard let context = extensions.context(id: id) else { return }
        let tab = pageTab.map { extensions.tabAdapter(for: $0) }
        context.performAction(for: tab)
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
