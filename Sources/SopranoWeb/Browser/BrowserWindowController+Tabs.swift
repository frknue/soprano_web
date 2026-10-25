import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Tabs

    /// A new tab at the end, the start page or `url`. A pop-up window has
    /// no tab list: its new tabs open in a window with tabs of its data
    /// context.
    @discardableResult
    func newTab(
        url: String? = nil,
        focusAddress: Bool = false,
        select: Bool = true
    ) -> BrowserTab {
        if isPopup {
            let target = manager.windowForNewTabs(from: self).window
            let tab = target.newTab(url: url, focusAddress: focusAddress, select: select)
            manager.present(target)
            return tab
        }
        let tab = makeTab()
        attachTab(tab, select: false)
        if let url, !url.isEmpty {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
        if select {
            selectTab(index: tabs.count - 1, focus: !focusAddress)
            if focusAddress {
                toolbar.focusAddress(selectAll: true)
            }
        }
        updateTabStrip()
        saveSession()
        return tab
    }

    /// A tab that belongs to no window yet: its web view (of this window's
    /// data store), page scripts and Vimium layer. `attachTab` binds it to a
    /// window. Nothing here refers to this window, so the tab can later
    /// move between the windows of its data context.
    func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let configuration = configuration ?? manager.makeTabConfiguration(for: dataContext)
        if configuration.urlSchemeHandler(forURLScheme: BrowserStartPageSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                manager.makeStartPageSchemeHandler(for: kind),
                forURLScheme: BrowserStartPageSchemeHandler.scheme
            )
        }
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: VimiumPageScripts.focusObserver,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        for script in BrowserPageScripts.all {
            contentController.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.injectionTime,
                forMainFrameOnly: script.forMainFrameOnly,
                in: script.world.contentWorld
            ))
        }
        configuration.userContentController = contentController

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        let tab = BrowserTab(webView: webView)
        let vimium = VimiumController(tab: tab)
        tab.vimium = vimium
        webView.keyHandler = { [weak vimium] event in
            vimium?.handle(event) ?? false
        }
        refreshStateScripts(tab)
        return tab
    }

    /// Adds a tab for a saved state without loading it; it loads, history
    /// included, when it is first selected (`loadRestoredTabIfNeeded`).
    @discardableResult
    func addRestoredTab(_ state: BrowserTabState, at index: Int? = nil) -> BrowserTab {
        let tab = makeTab()
        tab.title = state.url == nil && state.title.isEmpty ? "New Tab" : state.title
        tab.zoom = state.zoom
        tab.favicon = state.url.flatMap { faviconStore.image(forAddress: $0) }
        tab.isStartPage = false
        tab.lifecycle.pendingRestore = state
        attachTab(tab, at: index, select: false)
        return tab
    }

    // MARK: - Attach and detach

    /// Binds a live tab to this window and shows it in the tab list at
    /// `index` (nil: the end): navigation and UI delegates, the
    /// `sopranoWeb` and Vimium page-message handlers, the KVO observations,
    /// the Vimium controller's window, and the web view moves into this
    /// window's page area. `select` makes it the selected tab; otherwise the
    /// selection stays on the same tab. `detachTab` undoes all of it, so
    /// `detachTab` in one window plus `attachTab` in another moves a tab
    /// with its page, history and state.
    func attachTab(_ tab: BrowserTab, at index: Int? = nil, select: Bool) {
        guard !tabs.contains(where: { $0 === tab }) else { return }
        bindTab(tab)
        let webView = tab.webView
        webView.isHidden = true
        webArea.addSubview(webView)
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])

        let selectedID = selectedTab?.id
        let position = min(max(0, index ?? tabs.count), tabs.count)
        tabs.insert(tab, at: position)
        if select {
            selectTab(index: position, focus: true)
        } else if let selectedID, let selected = tabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = selected
            updateTabStrip()
        } else {
            // The window's first tab; the caller selects it (a restored tab
            // loads on selection).
            selectedIndex = position
        }
        saveSession()
    }

    /// Unbinds `tab` from this window and takes it out of the tab list and
    /// the page area, leaving a live tab for `attachTab` (in this or another
    /// window). A selected tab hands the selection to the tab at its index
    /// (or the last one). Returns false when the tab is not in this window.
    /// Detaching the last tab leaves an empty window; the caller closes it.
    @discardableResult
    func detachTab(_ tab: BrowserTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        let wasSelected = tab.id == selectedTab?.id
        let selectedID = selectedTab?.id
        unbindTab(tab)
        if wasSelected, !findBar.isHidden {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedIndex = 0
            tabStrip.clear()
            verticalTabsView.clear()
            updateChrome()
        } else if wasSelected {
            selectTab(index: min(index, tabs.count - 1), focus: true)
        } else if let selectedID, let kept = tabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = kept
            updateTabStrip()
        }
        saveSession()
        return true
    }

    private func bindTab(_ tab: BrowserTab) {
        let webView = tab.webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let contentController = webView.configuration.userContentController
        contentController.add(
            VimiumFocusHandler(controller: self, tabID: tab.id),
            name: VimiumPageScripts.focusMessageName
        )
        for world in BrowserPageScript.World.allCases {
            contentController.add(
                BrowserPageMessageHandler(controller: self, world: world),
                contentWorld: world.contentWorld,
                name: BrowserPageScripts.messageName
            )
        }
        observe(tab)
        observeSecurity(tab)
        observeCapture(tab)
        tab.vimium?.windowController = self
        if tab.isStartPage, webView.url != nil {
            // Rebuilt for this window's next selection (theme, bookmarks).
            staleStartTabs.insert(tab.id)
        }
    }

    private func unbindTab(_ tab: BrowserTab) {
        let webView = tab.webView
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        tab.invalidateObservations()
        tab.vimium?.shutdown()
        tab.vimium?.windowController = nil
        staleStartTabs.remove(tab.id)
        if linkStatus.tabID == tab.id {
            linkStatus.hide()
        }
        if previousSelectedTabID == tab.id {
            previousSelectedTabID = nil
        }
    }

    /// The window closed: every tab is unbound and released without
    /// selecting (and so loading) the lazily restored ones.
    func tearDown() {
        cancelStoreObservations()
        let closing = tabs
        tabs.removeAll()
        selectedIndex = 0
        for tab in closing {
            unbindTab(tab)
            tab.webView.removeFromSuperview()
            discardTab(tab)
        }
        tabStrip.clear()
        verticalTabsView.clear()
        addressBar.close()
    }

    private func observe(_ tab: BrowserTab) {
        let webView = tab.webView
        tab.observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    if let title = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !title.isEmpty
                    {
                        tab.title = title
                    }
                    self.metadataChanged(tab)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.tabURLChanged(tab)
                    self.sameDocumentURLChanged(tab)
                    self.metadataChanged(tab)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    self.metadataChanged(tab)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
                }
            },
        ]
    }

    func metadataChanged(_ tab: BrowserTab) {
        if tab.id == selectedTab?.id {
            updateChrome()
        }
        updateTabStrip()
        saveSession()
    }

    func selectTab(id: UUID, focus: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(index: index, focus: focus)
    }

    func selectTab(index: Int, focus: Bool) {
        guard tabs.indices.contains(index) else { return }
        let previous = selectedTab
        selectedIndex = index
        for tab in tabs {
            tab.webView.isHidden = tab.id != tabs[index].id
        }
        let tab = tabs[index]
        if let previous, previous.id != tab.id {
            previousSelectedTabID = previous.id
        }
        if tab.isStartPage, staleStartTabs.remove(tab.id) != nil {
            loadStartPage(tab)
        }
        prepareSelectedTab(tab)
        tabStrip.update(
            tabs: tabs.map(\.item),
            selectedID: tab.id
        )
        verticalTabsView.update(
            tabs: tabs.map(\.item),
            selectedID: tab.id
        )
        updateChrome()
        if focus {
            window?.makeFirstResponder(tab.webView)
        }
        saveSession()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(index: (selectedIndex + 1) % tabs.count, focus: true)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(index: (selectedIndex - 1 + tabs.count) % tabs.count, focus: true)
    }

    func selectTab(number: Int) {
        guard number >= 1, tabs.indices.contains(number - 1) else { return }
        selectTab(index: number - 1, focus: true)
    }

    /// Closes a tab onto the recently-closed stack (a private window's own).
    /// The last tab closes the window instead, which goes onto the stack as
    /// one window entry (a private window goes nowhere).
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs.count > 1 else {
            manager.closeWindow(self)
            return
        }
        let tab = tabs[index]
        let entry = BrowserClosedEntry(.tab(tab.state, windowID: self.id, index: index))
        if kind.usesAppRecentlyClosed {
            manager.recentlyClosed.push(entry)
        } else {
            closedTabs.push(entry)
        }
        detachTab(tab)
        discardTab(tab)
    }

    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(id: tab.id)
    }

    /// ⇧⌘T: the most recently closed tab or window, wherever it belongs; in
    /// a private window, this window's most recently closed tab.
    func reopenClosedTab() {
        guard !kind.usesAppRecentlyClosed else {
            manager.reopenMostRecent()
            return
        }
        guard let entry = closedTabs.pop(), case let .tab(state, _, index) = entry.content else { return }
        reopenTab(state, at: index)
    }

    /// Whether ⇧⌘T has something to reopen from this window.
    var canReopenClosedTab: Bool {
        kind.usesAppRecentlyClosed ? !manager.recentlyClosed.isEmpty : !closedTabs.isEmpty
    }

    /// Puts a reopened tab back at `index` (nil: the end) and selects it.
    func reopenTab(_ state: BrowserTabState, at index: Int?) {
        let tab = addRestoredTab(state, at: index)
        selectTab(id: tab.id, focus: true)
        updateTabStrip()
        saveSession()
    }

    func updateTabStrip() {
        guard let selectedTab else { return }
        let list = tabs.map(\.item)
        tabStrip.update(tabs: list, selectedID: selectedTab.id)
        verticalTabsView.update(tabs: list, selectedID: selectedTab.id)
    }

    func selectLastTab() {
        guard !tabs.isEmpty else { return }
        selectTab(index: tabs.count - 1, focus: true)
    }

    func selectPreviousVisitedTab() {
        guard let id = previousSelectedTabID,
              let index = tabs.firstIndex(where: { $0.id == id })
        else {
            showVimiumToast("No previous tab.")
            return
        }
        selectTab(index: index, focus: true)
    }

    /// Moves the tab to `index` (clamped to the tab list); the selection
    /// stays on the same tab.
    func moveTab(id: UUID, toIndex index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index), tabs.count - 1)
        guard target != from else { return }
        let selectedID = selectedTab?.id
        tabs.insert(tabs.remove(at: from), at: target)
        if let selectedID, let selected = tabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = selected
        }
        updateTabStrip()
        saveSession()
    }

    /// Copies the tab, back/forward list included, into a new selected tab
    /// right after it. Nil when there is no such tab.
    @discardableResult
    func duplicateTab(id: UUID) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = addRestoredTab(tabs[index].state, at: index + 1)
        selectTab(index: index + 1, focus: true)
        updateTabStrip()
        saveSession()
        return copy
    }

    func toggleMute(_ tab: BrowserTab) {
        tab.isMuted.toggle()
        applyMute(tab)
        metadataChanged(tab)
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }
}
