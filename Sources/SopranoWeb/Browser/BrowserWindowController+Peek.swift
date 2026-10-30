import AppKit
import WebKit

/// Peek (Arc's): a link opened over the page in a rounded panel with its
/// own web view, in the opener tab's data context. ⇧-click on any link and
/// a pinned or favorite tab's link to another site open one
/// (`BrowserLinkDisposition`); one per window, a second replaces it. Esc,
/// ⌘W, the close button or a click on the dimmed page close it; ⌘O or
/// "Open as Tab" makes its web view a Today tab after the opener, history
/// kept. Selecting another tab, switching Space or closing the opener
/// closes it. The Peek's tab gets every WebKit callback a tab gets
/// (`tab(for:)` finds it), so its History, downloads, sign-in sheets,
/// permissions, content blocking and extensions follow its data context;
/// nothing of it is saved in the session.
extension BrowserWindowController {
    /// The window's tabs and the Peek's: what refreshes of site decisions,
    /// content blocking and zoom walk.
    var tabsWithPeek: [BrowserTab] {
        peek.map { tabs + [$0.tab] } ?? tabs
    }

    /// The page the user looks at: the Peek's when one is open, else the
    /// selected tab's. Back, forward, reload, find and zoom act on it.
    var pageTab: BrowserTab? {
        peek?.tab ?? selectedTab
    }

    /// The tab a link from `tab`'s page opens after: a Peek's links open
    /// after the tab the Peek is over.
    func linkOpener(_ tab: BrowserTab) -> BrowserTab {
        guard let peek, peek.tab === tab else { return tab }
        return tabs.first { $0.id == peek.openerID } ?? tab
    }

    /// A tab of the window, or the Peek's, by id.
    func windowTab(id: UUID) -> BrowserTab? {
        if let tab = peek?.tab, tab.id == id {
            return tab
        }
        return tabs.first { $0.id == id }
    }

    // MARK: - Opening and closing

    /// Opens `url` in a Peek over `opener`'s page (a Peek's links: over the
    /// page under it), replacing an open Peek. From the Mini Player's page
    /// (not the one under a Peek) it opens as a foreground tab instead.
    @discardableResult
    func openPeek(_ url: URL, from opener: BrowserTab) -> BrowserTab {
        if manager.miniPlayer.hosts(opener) {
            return openLinkTab(url, opener: opener, select: true)
        }
        let tab = makeTab(context: opener.dataContext)
        showPeek(tab, from: opener)
        navigate(tab, to: url)
        return tab
    }

    /// Shows a tab made for the Peek (`makeTab`, or WebKit's configuration
    /// for a target=_blank link) over `opener`'s page.
    func showPeek(_ tab: BrowserTab, from opener: BrowserTab) {
        let opener = linkOpener(opener)
        closePeek(focusPage: false)
        // The hovered link's bubble belonged to the page under the Peek.
        linkStatus.hide()
        tab.isStartPage = false
        tab.origin = .today
        tab.links.openerID = opener.id
        if tabs.contains(where: { $0 === opener }) {
            tab.spaceID = opener.spaceID
        }
        let view = BrowserPeekView(theme: theme)
        view.onBack = { [weak self] in
            guard let self, let tab = self.peek?.tab else { return }
            self.goBack(tab)
        }
        view.onForward = { [weak self] in
            guard let self, let tab = self.peek?.tab else { return }
            self.goForward(tab)
        }
        view.onOpenAsTab = { [weak self] in self?.openPeekAsTab() }
        view.onClose = { [weak self] in self?.closePeek() }
        webArea.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: webArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])
        peek = BrowserPeek(tab: tab, openerID: opener.id, view: view)
        bindTab(tab)
        view.install(tab.webView)
        tab.webView.pageZoom = tab.zoom
        // The find bar stays above the page area's overlays.
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        extensions.tabAttached(tab, to: self)
        updatePeekChrome()
        window?.makeFirstResponder(tab.webView)
        refreshChromeForPageTab()
    }

    /// Closes the Peek and releases its page; the selected tab's page takes
    /// the focus the Peek had (`focusPage`). An open find bar searched the
    /// Peek's page, so it closes with it.
    func closePeek(focusPage: Bool = true) {
        guard let peek else { return }
        let hadFocus = peekHasFocus
        if !findBar.isHidden {
            hideFindBar(focus: false)
        }
        self.peek = nil
        let tab = peek.tab
        unbindTab(tab)
        peek.view.removeFromSuperview()
        discardTab(tab)
        // A Peek may close from its own page's callback (a link, Esc,
        // `window.close()`): its web view outlives the call.
        DispatchQueue.main.async { withExtendedLifetime(tab) {} }
        if focusPage, hadFocus, let selected = selectedTab {
            window?.makeFirstResponder(selected.webView)
        }
        refreshChromeForPageTab()
    }

    /// What follows the page shown (the Peek's or the selected tab's): the
    /// zoom, Reader and Translate chips, the capture indicator, the
    /// extensions' toolbar buttons, and Capture's overlay and Zap mode,
    /// which end with their page.
    private func refreshChromeForPageTab() {
        updateZoomChip()
        updateReaderChip()
        updateTranslateChip()
        updateCaptureIndicator()
        updateExtensionButtons()
        updateCaptureOverlay()
        updateZapSession()
    }

    /// ⌘O / "Open as Tab": the Peek's web view becomes a selected Today tab
    /// right after the tab it opened over (`insertLinkTab`; from a pop-up or
    /// Little Arc, in its Space's window), with its page and back/forward
    /// list. Nil without a Peek.
    @discardableResult
    func openPeekAsTab() -> BrowserTab? {
        guard let peek else { return nil }
        self.peek = nil
        let tab = peek.tab
        unbindTab(tab)
        tab.webView.removeFromSuperview()
        peek.view.removeFromSuperview()
        // Extensions see the tab move into the tab list.
        extensions.tabDetached(tab, from: self, index: tabs.count)
        tab.origin = .today
        tab.lifecycle.lastActiveAt = manager.tabSleeper.now()
        if let opener = tabs.first(where: { $0.id == peek.openerID }) {
            insertLinkTab(tab, opener: opener, select: true)
        } else {
            tab.spaceID = currentSpaceID
            attachTab(tab, select: true)
        }
        return tab
    }

    /// Whether the window's focus is in the Peek (its page or title bar).
    private var peekHasFocus: Bool {
        guard let peek, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: peek.view)
    }

    // MARK: - Chrome and keys

    /// The Peek's title bar follows its page.
    func updatePeekChrome() {
        guard let peek else { return }
        let tab = peek.tab
        let url = tab.failedURL.flatMap(URL.init(string:)) ?? tab.webView.url
        peek.view.update(
            title: tab.displayTitle,
            host: url.flatMap { BrowserPeekRule.siteHost($0.host) } ?? "",
            url: url?.absoluteString,
            canGoBack: tab.webView.canGoBack,
            canGoForward: tab.webView.canGoForward
        )
    }

    /// Esc in the Peek's page closes the Peek when Vimium and the page have
    /// nothing to end: an Esc that leaves a text field, hints, visual
    /// mode, Vimium's find or the find bar goes to them first, the next
    /// one closes the Peek; in element fullscreen it is WebKit's.
    func closesPeek(on event: NSEvent, in tab: BrowserTab) -> Bool {
        guard let peek, peek.tab === tab, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !vimiumFindActive,
              findBar.isHidden,
              tab.webView.fullscreenState == .notInFullscreen,
              tab.vimium?.isIdle ?? true
        else { return false }
        closePeek()
        return true
    }
}
