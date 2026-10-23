import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Tabs

    @discardableResult
    func newTab(
        url: String? = nil,
        focusAddress: Bool = false,
        select: Bool = true
    ) -> BrowserTab {
        let tab = makeTab()
        tabs.append(tab)
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

    func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let configuration = configuration ?? makeConfiguration()
        if configuration.urlSchemeHandler(forURLScheme: BrowserStartPageSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(
                BrowserStartPageSchemeHandler { [weak self] in self?.startPageHTML() ?? "" },
                forURLScheme: BrowserStartPageSchemeHandler.scheme
            )
        }
        let tabID = UUID()
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: VimiumPageScripts.focusObserver,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        contentController.add(
            VimiumFocusHandler(controller: self, tabID: tabID),
            name: VimiumPageScripts.focusMessageName
        )
        for script in BrowserPageScripts.all {
            contentController.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.injectionTime,
                forMainFrameOnly: script.forMainFrameOnly,
                in: script.world.contentWorld
            ))
        }
        for world in BrowserPageScript.World.allCases {
            contentController.add(
                BrowserPageMessageHandler(controller: self, world: world),
                contentWorld: world.contentWorld,
                name: BrowserPageScripts.messageName
            )
        }
        configuration.userContentController = contentController

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webArea.addSubview(webView)
        webArea.addSubview(findBar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
        ])

        let tab = BrowserTab(id: tabID, webView: webView)
        let vimium = VimiumController(windowController: self, tab: tab)
        tab.vimium = vimium
        webView.keyHandler = { [weak vimium] event in
            vimium?.handle(event) ?? false
        }
        observe(tab)
        return tab
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences = Self.makePreferences()
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        configuration.setURLSchemeHandler(
            BrowserStartPageSchemeHandler { [weak self] in self?.startPageHTML() ?? "" },
            forURLScheme: BrowserStartPageSchemeHandler.scheme
        )
        return configuration
    }

    func addRestoredTab(_ state: BrowserTabState) {
        let tab = makeTab()
        tab.title = state.title
        tab.zoom = state.zoom
        tab.suppressNextHistoryRecord = true
        tabs.append(tab)
        if let value = state.url,
           let url = URL(string: value)
        {
            tab.isStartPage = false
            tab.webView.load(URLRequest(url: url))
        } else {
            loadStartPage(tab)
        }
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
                    guard let self, let tab, tab.id == self.selectedTab?.id else { return }
                    self.updateChrome()
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

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        closedTabs.append(tab.state)
        if closedTabs.count > 20 {
            closedTabs.removeFirst(closedTabs.count - 20)
        }
        resolveLoadWaiters(
            for: tab,
            result: .failure(BrowserAutomationError.unavailable("The tab was closed."))
        )
        tab.vimium?.shutdown()
        tab.invalidateObservations()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            tabStrip.clear()
            verticalTabsView.clear()
            saveSession()
            window?.performClose(nil)
            return
        }

        let next = min(index, tabs.count - 1)
        selectTab(index: next, focus: true)
        updateTabStrip()
        saveSession()
    }

    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(id: tab.id)
    }

    func reopenClosedTab() {
        guard let state = closedTabs.popLast() else { return }
        addRestoredTab(state)
        selectTab(index: tabs.count - 1, focus: true)
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

    /// Opens the tab's page in a new selected tab. Nil when there is
    /// nothing to duplicate.
    @discardableResult
    func duplicateTab(id: UUID) -> BrowserTab? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        if tab.isStartPage {
            return newTab(focusAddress: false)
        } else if let url = tab.webView.url?.absoluteString {
            return newTab(url: url)
        }
        return nil
    }

    func toggleMute(_ tab: BrowserTab) {
        tab.isMuted.toggle()
        tab.webView.evaluateJavaScript(Self.muteScript(tab.isMuted)) { _, _ in }
        metadataChanged(tab)
    }

    private static func muteScript(_ muted: Bool) -> String {
        """
        (() => {
          window.__sopranoMuted = \(muted);
          document.querySelectorAll('audio, video').forEach((media) => {
            media.muted = window.__sopranoMuted;
          });
          return window.__sopranoMuted;
        })()
        """
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }
}
