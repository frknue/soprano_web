import AppKit
import WebKit

/// Per-tab link state: who opened the tab, the pop-ups its page tried to
/// open, and whether an external-app prompt is showing for it.
struct BrowserTabLinks {
    /// The tab whose link or `window.open` created this tab.
    var openerID: UUID?
    /// Blocked pop-ups on the current page, oldest first.
    var blockedPopups: [URL] = []
    /// URLs this tab's page opened as windows in the last moments.
    var recentlyOpened: [(url: URL, date: Date)] = []
    var isPromptingExternalApp = false
}

@MainActor
enum BrowserPopupScripts {
    /// Page world, document start, every frame: wraps `window.open` and
    /// reports calls WebKit's pop-up blocker turned into null.
    static let blockedPopupReporter = BrowserPageScript(
        source: """
        (() => {
          const original = window.open;
          const handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(BrowserPageScripts.messageName);
          if (typeof original !== 'function' || !handler) return;
          const noopener = (features) => String(features == null ? '' : features)
            .split(/[\\s,]+/)
            .some((token) => {
              const [name, value] = token.toLowerCase().split('=');
              return (name === 'noopener' || name === 'noreferrer')
                && !['0', 'no', 'false'].includes((value || '').trim());
            });
          const open = function open(url, target, features) {
            const result = Reflect.apply(original, this, arguments);
            if (result === null) {
              let absolute = 'about:blank';
              try {
                const raw = url == null ? '' : String(url);
                if (raw !== '') absolute = new URL(raw, document.baseURI).href;
              } catch (_) {}
              try {
                handler.postMessage({
                  type: 'popupBlocked',
                  url: absolute,
                  noopener: noopener(features),
                });
              } catch (_) {}
            }
            return result;
          };
          Object.defineProperty(window, 'open', {
            value: open, writable: true, configurable: true, enumerable: true,
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        world: .page
    )
}

extension BrowserWindowController {
    // MARK: - Link-opened tabs

    /// Opens `url` in a new tab right after `opener` (after the tabs it
    /// already opened), selected or in the background, in the opener's
    /// profile and Space.
    @discardableResult
    func openLinkTab(_ url: URL, opener: BrowserTab, select: Bool) -> BrowserTab {
        let tab = insertLinkTab(makeTab(context: opener.dataContext), opener: opener, select: select)
        navigate(tab, to: url)
        return tab
    }

    /// Attaches a freshly made tab (of the opener's data context) after its
    /// opener in the opener's Space and records the opener. From a pop-up
    /// window the tab opens at the end of the current Space of a window
    /// whose current Space uses the pop-up's data context instead; from a
    /// Little Arc, in a window showing its Space (`windowForNewTabs`). A
    /// tab opened from a hidden Space never takes the selection.
    @discardableResult
    func insertLinkTab(_ tab: BrowserTab, opener: BrowserTab, select: Bool) -> BrowserTab {
        if role.isCompact {
            let (target, isNewWindow) = manager.windowForNewTabs(from: self)
            tab.spaceID = target.currentSpaceID
            target.insertLinkTab(tab, opener: opener, select: select || isNewWindow)
            if select || isNewWindow {
                manager.present(target)
            }
            return tab
        }
        tab.isStartPage = false
        tab.links.openerID = opener.id
        if tabs.contains(where: { $0 === opener }) {
            tab.spaceID = opener.spaceID
        }
        let spaceTabs = tabs.filter { $0.spaceID == tab.spaceID }
        let index: Int
        if let openerIndex = spaceTabs.firstIndex(where: { $0.id == opener.id }) {
            index = BrowserLinkDisposition.insertionIndex(
                openerIndex: openerIndex,
                openerID: opener.id,
                openerIDs: spaceTabs.map(\.links.openerID)
            )
        } else {
            index = spaceTabs.count
        }
        attachTab(tab, at: index, select: select && tab.spaceID == currentSpaceID)
        return tab
    }

    /// `WKUIDelegate` body for `createWebViewWith`: a link with a target or a
    /// `window.open` call becomes a tab after its opener. ⌘ or middle opens
    /// it in the background; ⇧, or a pinned or favorite tab's link to
    /// another site, opens it in a Peek, ⌥ in a new split pane (WebKit's
    /// configuration, so the page keeps its opener). A plain `window.open`
    /// that asks for a width or height opens a pop-up window of that size
    /// instead; a scripted one never opens a Peek or a pane.
    func createLinkWebView(
        from webView: WKWebView,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: BrowserPopupFeatures
    ) -> WKWebView? {
        // WebKit hands over the opener's preferences object; give the new tab
        // its own so per-site pop-up permission stays per tab.
        configuration.preferences = Self.makePreferences()
        let opener = self.tab(for: webView)
        let tab = makeTab(context: opener?.dataContext ?? dataContext, configuration: configuration)
        let disposition = navigationAction.navigationType == .linkActivated
            ? BrowserLinkDisposition.disposition(
                modifierFlags: navigationAction.modifierFlags,
                buttonNumber: navigationAction.buttonNumber,
                origin: opener?.origin ?? .today,
                pageURL: webView.url,
                linkURL: navigationAction.request.url,
                targetsMainFrame: true
            )
            : BrowserLinkDisposition.scriptedDisposition(
                modifierFlags: navigationAction.modifierFlags,
                buttonNumber: navigationAction.buttonNumber
            )
        if let opener {
            if let url = navigationAction.request.url {
                let now = Date()
                opener.links.recentlyOpened = opener.links.recentlyOpened
                    .filter { now.timeIntervalSince($0.date) < 5 } + [(url, now)]
            }
            // A Peek would show over the window's page, not the Mini Player's.
            if disposition == .peek, !manager.miniPlayer.hosts(opener) {
                showPeek(tab, from: opener)
            } else if disposition == .splitPane {
                insertLinkPane(tab, opener: linkOpener(opener))
            } else if disposition == .currentTab, windowFeatures.opensWindow {
                tab.isStartPage = false
                tab.links.openerID = opener.id
                manager.openPopupWindow(with: tab, features: windowFeatures, opener: self)
            } else {
                insertLinkTab(tab, opener: linkOpener(opener), select: disposition != .backgroundTab)
            }
        } else {
            tab.isStartPage = false
            tab.spaceID = currentSpaceID
            attachTab(tab, select: true)
        }
        return tab.webView
    }

    static func makePreferences() -> WKPreferences {
        let preferences = WKPreferences()
        preferences.isElementFullscreenEnabled = true
        preferences.javaScriptCanOpenWindowsAutomatically = false
        return preferences
    }

    /// Link work in `decidePolicyFor navigationAction`, after the scheme and
    /// download checks. A ⌘/⇧⌘/middle click on a link that targets a frame in
    /// this tab opens a new tab instead, ⇧ or a pinned or favorite tab's
    /// link to another site a Peek, ⌥ a split pane (returns true: cancel).
    /// A main-frame load gets the pop-up permission of the page it is
    /// about to show.
    func handleLinkNavigation(_ navigationAction: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard let url = navigationAction.request.url, let tab = tab(for: webView) else { return false }
        if navigationAction.navigationType == .linkActivated,
           let targetFrame = navigationAction.targetFrame,
           navigationAction.sourceFrame.webView === webView
        {
            let disposition = BrowserLinkDisposition.disposition(
                modifierFlags: navigationAction.modifierFlags,
                buttonNumber: navigationAction.buttonNumber,
                origin: tab.origin,
                pageURL: webView.url,
                linkURL: url,
                targetsMainFrame: targetFrame.isMainFrame
            )
            switch disposition {
            case .peek:
                openPeek(url, from: tab)
                return true
            case .splitPane:
                openLinkPane(url, from: linkOpener(tab))
                return true
            case .backgroundTab, .foregroundTab:
                openLinkTab(url, opener: linkOpener(tab), select: disposition == .foregroundTab)
                return true
            case .currentTab:
                break
            }
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            applyPopupPermission(tab, pageURL: url)
        }
        return false
    }

    /// ⌥-click: `url` in a new Today tab beside `opener` that joins its
    /// split right of it (a split of the two when it has none), focused.
    /// When the split is full, or the window has no splits (a pop-up, a
    /// Little Arc), it opens as a foreground tab instead.
    @discardableResult
    func openLinkPane(_ url: URL, from opener: BrowserTab) -> BrowserTab {
        let tab = insertLinkPane(makeTab(context: opener.dataContext), opener: opener)
        navigate(tab, to: url)
        return tab
    }

    /// `insertLinkTab` for a tab made for a split pane, which then joins
    /// `opener`'s split (`openLinkPane`).
    @discardableResult
    func insertLinkPane(_ tab: BrowserTab, opener: BrowserTab) -> BrowserTab {
        let joins = allowsSplits && tabs.contains { $0 === opener }
            && opener.spaceID == currentSpaceID
            && !(split(containing: opener.id)?.isFull ?? false)
        insertLinkTab(tab, opener: opener, select: !joins)
        if joins {
            addPane(tab, to: opener, at: nil, focus: true)
        }
        return tab
    }

    // MARK: - window.close()

    /// `window.close()`: closes the tab; a selected tab returns to the tab
    /// that opened it when that tab is still open.
    func webViewDidClose(_ webView: WKWebView) {
        if let peekTab = peek?.tab, peekTab.webView === webView {
            closePeek()
            return
        }
        guard let tab = tab(for: webView) else { return }
        let wasSelected = tab.id == selectedTab?.id
        let previousID = selectedTab?.id
        let openerID = tab.links.openerID
        closeTab(id: tab.id)
        guard !tabs.isEmpty else { return }
        if wasSelected, let openerID, tabs.contains(where: { $0.id == openerID }) {
            selectTab(id: openerID, focus: true)
        } else if !wasSelected, let previousID {
            selectTab(id: previousID, focus: false)
        }
    }

    // MARK: - Pop-up blocker

    /// Lets the tab's page open windows without a click when its host is
    /// allowed. WebKit reads the preference when `window.open` runs, so it
    /// is set for the page about to load and again once it commits.
    func applyPopupPermission(_ tab: BrowserTab, pageURL: URL?) {
        let allowed = BrowserPopupPolicy.opensWithoutGesture(
            pageURL: pageURL,
            permissions: tab.dataContext.sitePermissions
        )
        let preferences = tab.webView.configuration.preferences
        if preferences.javaScriptCanOpenWindowsAutomatically != allowed {
            preferences.javaScriptCanOpenWindowsAutomatically = allowed
        }
    }

    /// Re-applies the stored pop-up decisions to every open page, e.g. after
    /// a decision changed in Settings.
    func refreshPopupPermissions() {
        for tab in tabsWithPeek {
            applyPopupPermission(tab, pageURL: tab.webView.url)
        }
    }

    /// Main-frame commit: the new page starts without blocked pop-ups.
    func linksDidCommit(_ tab: BrowserTab) {
        applyPopupPermission(tab, pageURL: tab.webView.url)
        guard !tab.links.blockedPopups.isEmpty else { return }
        tab.links.blockedPopups = []
        if tab.id == selectedTab?.id {
            updatePopupBlockedControl()
        }
    }

    func receivePopupBlocked(body: [String: Any], tab: BrowserTab) {
        let now = Date()
        tab.links.recentlyOpened = tab.links.recentlyOpened.filter { now.timeIntervalSince($0.date) < 5 }
        guard let url = BrowserPopupPolicy.blockedURL(
            body["url"] as? String,
            noopener: body["noopener"] as? Bool ?? false,
            recentlyOpened: tab.links.recentlyOpened.map(\.url)
        ) else { return }
        tab.links.blockedPopups = BrowserPopupPolicy.appending(url, to: tab.links.blockedPopups)
        if tab.id == selectedTab?.id {
            updatePopupBlockedControl()
        }
    }

    /// Shows the selected tab's blocked pop-ups in the address field.
    func updatePopupBlockedControl() {
        let blocked = selectedTab?.links.blockedPopups ?? []
        if blocked.isEmpty {
            popupBlockedControl?.isHidden = true
            return
        }
        let control: ChromeButton
        if let existing = popupBlockedControl {
            control = existing
        } else {
            control = ChromeButton(
                title: "Pop-up blocked",
                theme: theme,
                kind: .standard,
                target: self,
                action: #selector(popupBlockedControlPressed(_:))
            )
            control.setAccessibilityLabel("Pop-up blocked")
            control.heightAnchor.constraint(equalToConstant: 20).isActive = true
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            toolbar.addressAccessories.addArrangedSubview(control)
            popupBlockedControl = control
        }
        control.apply(theme: theme)
        control.title = blocked.count == 1 ? "Pop-up blocked" : "\(blocked.count) pop-ups blocked"
        control.toolTip = blocked.count == 1
            ? "This page tried to open \(blocked[0].absoluteString)"
            : "This page tried to open \(blocked.count) pop-ups"
        control.isHidden = false
    }

    @objc func popupBlockedControlPressed(_ sender: NSButton) {
        guard let tab = selectedTab, !tab.links.blockedPopups.isEmpty else { return }
        let menu = NSMenu()
        for url in tab.links.blockedPopups.reversed() {
            let item = NSMenuItem(
                title: "Open \(Self.shortDisplay(url))",
                action: #selector(openBlockedPopup(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.toolTip = url.absoluteString
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let host = BrowserSitePermissionStore.key(for: tab.webView.url) {
            let item = NSMenuItem(
                title: "Always Allow Pop-ups on \(host)",
                action: #selector(allowPopupsForSelectedSite(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = host
            menu.addItem(item)
        }
        let dismiss = NSMenuItem(title: "Dismiss", action: #selector(dismissBlockedPopups(_:)), keyEquivalent: "")
        dismiss.target = self
        menu.addItem(dismiss)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func openBlockedPopup(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let tab = selectedTab else { return }
        tab.links.blockedPopups.removeAll { $0 == url }
        updatePopupBlockedControl()
        openLinkTab(url, opener: tab, select: true)
    }

    @objc func allowPopupsForSelectedSite(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String, let tab = selectedTab else { return }
        tab.dataContext.sitePermissions.set(.popups, .allow, host: host)
        refreshPopupPermissions()
        tab.links.blockedPopups = []
        updatePopupBlockedControl()
    }

    @objc func dismissBlockedPopups(_ sender: Any?) {
        selectedTab?.links.blockedPopups = []
        updatePopupBlockedControl()
    }

    private static func shortDisplay(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    // MARK: - External apps

    /// A page's link to another app (`mailto:`, `zoommtg:`, …): open it when
    /// the site is allowed, otherwise ask once per tab at a time.
    func openExternalLink(_ url: URL, from webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        let permissions = tab.dataContext.sitePermissions
        switch BrowserExternalAppPolicy.decision(for: url, pageURL: webView.url, permissions: permissions) {
        case .block:
            return
        case .open:
            if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
                showNoAppToast(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .prompt(let host):
            promptExternalApp(url, tab: tab, host: host)
        }
    }

    /// An extension's link to another app (`tabs.update`, its popup's
    /// link): always asks, naming the extension; never remembered for the
    /// tab's site.
    func openExternalLink(_ url: URL, fromExtension name: String, in tab: BrowserTab) {
        promptExternalApp(url, tab: tab, host: nil, requester: "“\(name)”")
    }

    private func promptExternalApp(_ url: URL, tab: BrowserTab, host: String?, requester: String? = nil) {
        guard !tab.links.isPromptingExternalApp else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            showNoAppToast(url)
            return
        }
        guard let window else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        let appName = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        let site = requester ?? host ?? "This page"
        let alert = NSAlert()
        alert.messageText = "Open “\(appName)”?"
        alert.informativeText = "\(site) wants to open this link in \(appName)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if let host {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Always allow \(host) to open \(scheme) links"
            alert.suppressionButton?.state = .off
        }
        tab.links.isPromptingExternalApp = true
        let permissions = tab.dataContext.sitePermissions
        alert.beginSheetModal(for: window) { [weak tab] response in
            MainActor.assumeIsolated {
                tab?.links.isPromptingExternalApp = false
                guard response == .alertFirstButtonReturn else { return }
                if let host, alert.suppressionButton?.state == .on {
                    permissions.set(.externalApp(scheme: scheme), .allow, host: host)
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showNoAppToast(_ url: URL) {
        showVimiumToast("No app can open “\(url.scheme ?? "")” links.")
    }
}
