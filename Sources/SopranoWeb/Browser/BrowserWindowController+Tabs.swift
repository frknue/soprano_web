import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Tabs

    /// A new Today tab at the end of the current Space, the start page or
    /// `url`, of the current Space's profile. A pop-up window has no tab
    /// list: its new tabs open in a window whose current Space uses its
    /// data context.
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
        let tab = makeTab(context: dataContext)
        tab.spaceID = currentSpaceID
        attachTab(tab, select: false)
        if let url, !url.isEmpty {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
        if select {
            selectTab(id: tab.id, focus: !focusAddress)
            if focusAddress {
                focusAddressBar()
            }
        }
        updateTabStrip()
        saveSession()
        return tab
    }

    /// A tab of `context` that belongs to no window yet: its web view (of
    /// the context's data store, or of `configuration`, a pop-up's), page
    /// scripts and Vimium layer. `attachTab` binds it to a window. Nothing
    /// here refers to this window, so the tab can later move into any
    /// window whose current Space uses `context`.
    func makeTab(context: BrowserDataContext, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(
            webView: makeWebView(context: context, configuration: configuration),
            dataContext: context,
            zoom: settingsStore.settings.defaultZoom
        )
        tab.vimium = VimiumController(tab: tab)
        connectKeyHandler(tab)
        refreshStateScripts(tab)
        tab.lifecycle.lastActiveAt = manager.tabSleeper.now()
        return tab
    }

    /// An empty web view of `context` (or of `configuration`, a pop-up's)
    /// with every page script and the content blocker's lists. It starts
    /// no web content process until it loads.
    private func makeWebView(context: BrowserDataContext, configuration: WKWebViewConfiguration?) -> BrowserWebView {
        let configuration = configuration ?? manager.makeTabConfiguration(for: context)
        if configuration.urlSchemeHandler(forURLScheme: BrowserStartPageSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                manager.makeStartPageSchemeHandler(),
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
        // Every new web view (a tab, a pop-up, a tab waking from sleep)
        // starts with the lists; its first navigation re-checks its site.
        applyContentBlocking(to: webView, pageURL: nil, in: context)
        return webView
    }

    private func connectKeyHandler(_ tab: BrowserTab) {
        tab.webView.keyHandler = { [weak vimium = tab.vimium] event in
            vimium?.handle(event) ?? false
        }
    }

    /// Swaps the tab's web view for a fresh, empty one of the tab's data
    /// context, so the old one and its web content process go away (a tab
    /// falling asleep). The tab keeps its place, selection and bindings;
    /// the caller has saved what the page needs to come back
    /// (`lifecycle.pendingRestore`).
    func replaceWebView(of tab: BrowserTab) {
        let attached = tabs.contains { $0 === tab }
        let previousSelection = previousSelectedTabID
        if attached {
            unbindTab(tab)
        }
        let old = tab.webView
        old.stopLoading()
        old.removeFromSuperview()
        tab.replaceWebView(with: makeWebView(context: tab.dataContext, configuration: nil))
        tab.media.frames.removeAll()
        tab.media.audio.reset()
        connectKeyHandler(tab)
        refreshStateScripts(tab)
        guard attached else { return }
        bindTab(tab)
        installWebView(tab.webView)
        tab.webView.isHidden = tab.id != selectedTab?.id
        previousSelectedTabID = previousSelection
    }

    /// Adds a tab for a saved state without loading it; it loads, history
    /// included, when it is first selected (`loadRestoredTabIfNeeded`). In
    /// a window with Spaces it joins the state's Space (the current Space
    /// when the state has none or it is gone) with that Space's profile
    /// context and keeps its pin or favorite link; elsewhere it is a tab
    /// of the window's context. `index` counts the tabs of its Space.
    @discardableResult
    func addRestoredTab(_ state: BrowserTabState, at index: Int? = nil) -> BrowserTab {
        let space = hasSpaces
            ? (state.spaceID.flatMap(spaces.space(id:)) ?? currentSpaceID.flatMap(spaces.space(id:)))
            : nil
        let context = space.map { manager.context(for: $0.profileID) } ?? dataContext
        let tab = makeTab(context: context)
        tab.spaceID = space?.id
        // A link whose pin or favorite is gone, or that already has a live
        // tab here, becomes a Today tab.
        tab.origin = space.map { space in
            BrowserPinLinks.originAfterMove(
                state.origin,
                into: spaces.linkTargets(inSpace: space.id),
                live: tabs.map(\.origin)
            )
        } ?? .today
        tab.linkLanding = tab.origin == .today ? nil : state.linkLanding
        tab.title = state.url == nil && state.title.isEmpty ? "New Tab" : state.title
        tab.zoom = settingsStore.settings.defaultZoom
        tab.favicon = state.url.flatMap { context.faviconStore.image(forAddress: $0) }
        tab.isStartPage = false
        tab.lifecycle.pendingRestore = state
        // Idle time carries over the relaunch (the Archive, tab sleep).
        if let lastActiveAt = state.lastActiveAt {
            tab.lifecycle.lastActiveAt = lastActiveAt
        }
        attachTab(tab, at: index, select: false)
        return tab
    }

    // MARK: - Attach and detach

    /// Binds a live tab to this window and shows it in its Space's tab list
    /// at `index` (counted among that Space's tabs; nil or past the end:
    /// the end): navigation and UI delegates, the `sopranoWeb` and Vimium
    /// page-message handlers, the KVO observations, the Vimium controller's
    /// window, and the web view moves into this window's page area. The
    /// tab keeps `spaceID` when it names a Space (a window without Spaces
    /// clears it; an unknown one becomes the current Space). `select`
    /// makes it the selected tab (switching to its Space); otherwise the
    /// selection stays on the same tab. `detachTab` undoes all of it, so
    /// `detachTab` in one window plus `attachTab` in another moves a tab
    /// with its page, history and state.
    func attachTab(_ tab: BrowserTab, at index: Int? = nil, select: Bool) {
        guard !tabs.contains(where: { $0 === tab }) else { return }
        if !hasSpaces {
            tab.spaceID = nil
        } else if tab.spaceID.flatMap(spaces.space(id:)) == nil {
            tab.spaceID = currentSpaceID
        }
        bindTab(tab)
        installWebView(tab.webView)

        let selectedID = selectedTab?.id
        let spaceTabs = tabs.filter { $0.spaceID == tab.spaceID }
        let position: Int
        if let index, spaceTabs.indices.contains(max(0, index)),
           let before = tabs.firstIndex(where: { $0 === spaceTabs[max(0, index)] })
        {
            position = before
        } else {
            position = tabs.count
        }
        tabs.insert(tab, at: position)
        if let selectedID, let selected = visibleTabs.firstIndex(where: { $0.id == selectedID }) {
            // The selection stays on its tab (and is the one `select` leaves).
            selectedIndex = selected
        } else if let visible = visibleTabs.firstIndex(where: { $0 === tab }) {
            // The Space's first tab; the caller selects it (a restored tab
            // loads on selection).
            selectedIndex = visible
        }
        syncContextObservations()
        if select {
            selectTab(id: tab.id, focus: true)
        } else if selectedID != nil {
            updateTabStrip()
        }
        if tab.isAsleep {
            // A sleeping tab wakes when it moves to another window.
            loadRestoredTabIfNeeded(tab)
        }
        saveSession()
    }

    /// Puts a web view in the page area, hidden, under the find bar.
    private func installWebView(_ webView: BrowserWebView) {
        webView.isHidden = true
        webArea.addSubview(webView)
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])
    }

    /// Unbinds `tab` from this window and takes it out of the tab list and
    /// the page area, leaving a live tab for `attachTab` (in this or another
    /// window). A selected tab hands the selection to the tab at its index
    /// in the Space (or the Space's last one); a Space left without tabs
    /// while the window has others gets a start tab. Returns false when the
    /// tab is not in this window. Detaching the last tab leaves an empty
    /// window; the caller closes it.
    @discardableResult
    func detachTab(_ tab: BrowserTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        let visibleIndex = visibleTabs.firstIndex { $0 === tab }
        let wasSelected = tab.id == selectedTab?.id
        let selectedID = selectedTab?.id
        unbindTab(tab)
        if wasSelected, !findBar.isHidden {
            tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
        removeWakeSnapshot(tab)
        tab.webView.removeFromSuperview()
        if let spaceID = tab.spaceID, spaceSelections[spaceID] == tab.id {
            spaceSelections[spaceID] = nil
        }
        tabs.remove(at: index)
        syncContextObservations()

        if tabs.isEmpty {
            selectedIndex = 0
            tabStrip.clear()
            verticalTabsView.clear()
            updateChrome()
        } else if visibleTabs.isEmpty {
            // The current Space's last tab left; it shows a start tab.
            selectedIndex = 0
            newTab()
        } else if wasSelected, let visibleIndex {
            selectTab(index: min(visibleIndex, visibleTabs.count - 1), focus: true)
        } else if let selectedID, let kept = visibleTabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = kept
            updateTabStrip()
        }
        saveSession()
        return true
    }

    /// `detachTab` for many tabs at once, with the window's UI work done
    /// once: one `tabs` change, one observation sync, one selection change,
    /// one tab strip and rail update, one session save. (Each rail or strip
    /// update rebuilds its rows, tens of milliseconds a time.) The result is
    /// what detaching them one by one gives: a selected tab hands the
    /// selection to the first remaining tab after it in the Space, else the
    /// Space's last; a Space left without tabs gets a start tab. Returns the
    /// tabs that were in the window.
    @discardableResult
    func detachTabs(_ leaving: [BrowserTab]) -> [BrowserTab] {
        let present = leaving.filter { tab in tabs.contains { $0 === tab } }
        guard present.count > 1 else {
            present.forEach { detachTab($0) }
            return present
        }
        let leavingIDs = Set(present.map(\.id))
        let oldVisible = visibleTabs
        let selected = selectedTab
        let wasSelected = selected.map { leavingIDs.contains($0.id) } ?? false
        // Where the selection goes: the first tab after it that stays.
        let successor = selected.flatMap { selected in
            oldVisible.firstIndex { $0 === selected }.flatMap { index in
                oldVisible[(index + 1)...].first { !leavingIDs.contains($0.id) }?.id
            }
        }
        if wasSelected, !findBar.isHidden {
            selected?.webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
        for tab in present {
            unbindTab(tab)
            removeWakeSnapshot(tab)
            tab.webView.removeFromSuperview()
            if let spaceID = tab.spaceID, spaceSelections[spaceID] == tab.id {
                spaceSelections[spaceID] = nil
            }
        }
        tabs.removeAll { leavingIDs.contains($0.id) }
        syncContextObservations()

        if tabs.isEmpty {
            selectedIndex = 0
            tabStrip.clear()
            verticalTabsView.clear()
            updateChrome()
        } else if visibleTabs.isEmpty {
            // The current Space's last tabs left; it shows a start tab.
            selectedIndex = 0
            newTab()
        } else if wasSelected {
            let target = successor.flatMap { id in visibleTabs.firstIndex { $0.id == id } } ?? visibleTabs.count - 1
            selectTab(index: target, focus: true)
        } else if let selectedID = selected?.id, let kept = visibleTabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = kept
            updateTabStrip()
        }
        saveSession()
        return present
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
            // Rebuilt for this window's next selection (theme, pins).
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
        cancelRecentTabs()
        let closing = tabs
        tabs.removeAll()
        selectedIndex = 0
        spaceSelections.removeAll()
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
                        self.lateTitleChanged(tab, title: title)
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

    // MARK: - Selection

    /// Selects tab `id`, switching to its Space when it is in another one.
    func selectTab(id: UUID, focus: Bool) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if hasSpaces, let spaceID = tab.spaceID, spaceID != currentSpaceID {
            switchToSpace(spaceID, selecting: id, focus: focus)
            return
        }
        guard let index = visibleTabs.firstIndex(where: { $0.id == id }) else { return }
        selectTab(index: index, focus: focus)
    }

    /// Selects the current Space's tab at `index` of `visibleTabs`.
    func selectTab(index: Int, focus: Bool) {
        guard visibleTabs.indices.contains(index) else { return }
        let previous = selectedTab
        selectedIndex = index
        showSelectedTab(leaving: previous, focus: focus)
    }

    /// Shows `visibleTabs[selectedIndex]` (every other page hidden), loads
    /// it when it is not loaded, remembers it as its Space's selection and
    /// refreshes the tab list and chrome. `previous` is the tab selected
    /// before (of this or, on a Space switch, the Space left); its idle time
    /// starts now.
    func showSelectedTab(leaving previous: BrowserTab?, focus: Bool) {
        guard visibleTabs.indices.contains(selectedIndex) else { return }
        let tab = visibleTabs[selectedIndex]
        for other in tabs {
            other.webView.isHidden = other !== tab
        }
        tabWasUsed(tab)
        recentTabs.touch(tab.id)
        if commandBar.isOpen, previous?.id != tab.id {
            // ⌘L's address and ⌘T's results were the old tab's.
            commandBar.close()
        }
        if let previous, previous.id != tab.id {
            previousSelectedTabID = previous.id
            previous.lifecycle.lastActiveAt = tab.lifecycle.lastActiveAt
            removeWakeSnapshot(previous)
        }
        if let spaceID = currentSpaceID {
            spaceSelections[spaceID] = tab.id
        }
        if tab.isStartPage, staleStartTabs.remove(tab.id) != nil {
            loadStartPage(tab)
        }
        prepareSelectedTab(tab)
        updateTabStrip()
        updateChrome()
        if focus {
            window?.makeFirstResponder(tab.webView)
        }
        saveSession()
    }

    func selectNextTab() {
        guard visibleTabs.count > 1 else { return }
        selectTab(index: (selectedIndex + 1) % visibleTabs.count, focus: true)
    }

    func selectPreviousTab() {
        guard visibleTabs.count > 1 else { return }
        selectTab(index: (selectedIndex - 1 + visibleTabs.count) % visibleTabs.count, focus: true)
    }

    /// ⌘1…⌘8 and Vimium's `<n>gt`: the current Space's tab `number`.
    func selectTab(number: Int) {
        guard number >= 1, visibleTabs.indices.contains(number - 1) else { return }
        selectTab(index: number - 1, focus: true)
    }

    func selectLastTab() {
        guard !visibleTabs.isEmpty else { return }
        selectTab(index: visibleTabs.count - 1, focus: true)
    }

    func selectPreviousVisitedTab() {
        guard let id = previousSelectedTabID, tabs.contains(where: { $0.id == id }) else {
            showVimiumToast("No previous tab.")
            return
        }
        selectTab(id: id, focus: true)
    }

    // MARK: - Closing and reopening

    /// Closes a tab onto the recently-closed stack (a private window's own)
    /// with its Space and its index there; with `archive` (the user closed
    /// it: ⌘W, its close button or menu, the CLI) a Today tab also goes
    /// into the Archive (reason manual; `recordArchive` skips start pages
    /// and private windows). A pinned or favorite tab unloads back to its
    /// pin instead (`unloadLinkedTab`). The window's last tab closes the
    /// window instead, which goes onto the stack as one window entry (a
    /// private window goes nowhere). A Space's only tab, when it is the
    /// start page, stays: closing it would only open another.
    func closeTab(id: UUID, archive: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if hasSpaces, tab.origin != .today {
            unloadLinkedTab(tab)
            return
        }
        guard tabs.count > 1 else {
            if archive {
                recordArchive(tab, reason: .manual)
            }
            manager.closeWindow(self)
            return
        }
        if hasSpaces, tab.isStartPage, visibleTabs.count == 1, visibleTabs.first === tab {
            return
        }
        let index = tabs.filter { $0.spaceID == tab.spaceID }.firstIndex { $0 === tab }
        let entry = BrowserClosedEntry(
            .tab(tab.state, windowID: self.id, index: index),
            profileID: tab.dataContext.profileID
        )
        if kind.usesAppRecentlyClosed {
            manager.recentlyClosed.push(entry)
        } else {
            closedTabs.push(entry)
        }
        if archive {
            recordArchive(tab, reason: .manual)
        }
        detachTab(tab)
        discardTab(tab)
    }

    /// ⌘W: closes (and archives, for a Today tab) the selected tab.
    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(id: tab.id, archive: true)
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

    /// Puts a reopened tab back, as a Today tab, in its Space at `index`
    /// (nil: the end) and selects it (switching to its Space).
    func reopenTab(_ state: BrowserTabState, at index: Int?) {
        var state = state
        state.origin = .today
        let tab = addRestoredTab(state, at: index)
        // ⌘W archived it; back open, it leaves the Archive.
        if !kind.isPrivate, let url = state.url {
            manager.archive.removeEntry(url: url, profileID: tab.dataContext.profileID)
        }
        selectTab(id: tab.id, focus: true)
        updateTabStrip()
        saveSession()
    }

    // MARK: - Tab list

    /// Refreshes the tab strip and the rail from `visibleTabs`.
    func updateTabStrip() {
        guard let selectedTab else { return }
        tabStrip.update(tabs: visibleTabs.map(tabItem), selectedID: selectedTab.id)
        updateRail()
    }

    /// Moves the current Space's tab to `index` of the Space's tabs
    /// (clamped); the other Spaces' tabs keep their places and the
    /// selection stays on the same tab.
    func moveTab(id: UUID, toIndex index: Int) {
        guard let from = visibleTabs.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index), visibleTabs.count - 1)
        guard target != from else { return }
        let selectedID = selectedTab?.id
        var order = visibleTabs
        order.insert(order.remove(at: from), at: target)
        // The Space's tabs take their old places in the window, reordered.
        var next = order.startIndex
        let space = currentSpaceID
        tabs = tabs.map { tab in
            guard tab.spaceID == space else { return tab }
            defer { next += 1 }
            return order[next]
        }
        if let selectedID, let selected = visibleTabs.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = selected
        }
        updateTabStrip()
        saveSession()
    }

    /// Copies the tab, back/forward list included, into a new selected Today
    /// tab right after it in its Space. Nil when there is no such tab.
    @discardableResult
    func duplicateTab(id: UUID) -> BrowserTab? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let index = tabs.filter { $0.spaceID == tab.spaceID }.firstIndex { $0 === tab } ?? 0
        var state = tab.state
        state.origin = .today
        let copy = addRestoredTab(state, at: index + 1)
        selectTab(id: copy.id, focus: true)
        updateTabStrip()
        saveSession()
        return copy
    }

    func toggleMute(_ tab: BrowserTab) {
        tab.isMuted.toggle()
        applyMute(tab)
        metadataChanged(tab)
    }

    /// The tab of any Space whose web view is `webView`.
    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }
}
