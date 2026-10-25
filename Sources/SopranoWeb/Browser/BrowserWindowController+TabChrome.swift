import AppKit
import WebKit

extension BrowserWindowController {
    // MARK: - Tab chrome

    /// Wires favicons, the link-hover bubble, the navigation buttons and the
    /// tab views' drag, mute and context-menu callbacks. Runs once from init.
    func installTabChrome() {
        rootView.addSubview(linkStatus)
        NSLayoutConstraint.activate([
            linkStatus.leadingAnchor.constraint(equalTo: webArea.leadingAnchor, constant: BrowserLinkStatusView.inset),
            linkStatus.bottomAnchor.constraint(equalTo: webArea.bottomAnchor, constant: -BrowserLinkStatusView.inset),
            linkStatus.widthAnchor.constraint(
                lessThanOrEqualTo: webArea.widthAnchor,
                multiplier: BrowserLinkStatusView.maximumWidthFraction
            ),
        ])

        let controls = toolbar.navigationControls
        controls.onBack = { [weak self] in self?.goBack() }
        controls.onForward = { [weak self] in self?.goForward() }
        controls.onReloadOrStop = { [weak self] in self?.reloadOrStop() }
        controls.historyMenu = { [weak self] direction in self?.historyMenu(direction) }

        tabStrip.onReorder = { [weak self] id, index in self?.moveTab(id: id, toIndex: index) }
        tabStrip.onToggleMute = { [weak self] id in self?.toggleMute(id: id) }
        tabStrip.contextMenuProvider = { [weak self] id in
            self?.tabContextMenu(for: id, closeAfterTitle: "Close Tabs to the Right")
        }
        verticalTabsView.onReorder = { [weak self] id, index in self?.moveTab(id: id, toIndex: index) }
        verticalTabsView.onToggleMute = { [weak self] id in self?.toggleMute(id: id) }
        verticalTabsView.contextMenuProvider = { [weak self] id in
            self?.tabContextMenu(for: id, closeAfterTitle: "Close Tabs Below")
        }
        // Tabs dragged between windows, or out of every window.
        tabStrip.canAcceptTab = { [weak self] id in self?.canAcceptDroppedTab(id: id) ?? false }
        tabStrip.onDropTab = { [weak self] id, index in self?.dropTab(id: id, at: index) }
        tabStrip.onDragOut = { [weak self] id, point in self?.tabDraggedOut(id: id, to: point) }
        verticalTabsView.canAcceptTab = { [weak self] id in self?.canAcceptDroppedTab(id: id) ?? false }
        verticalTabsView.onDropTab = { [weak self] id, index in self?.dropTab(id: id, at: index) }
        verticalTabsView.onDragOut = { [weak self] id, point in self?.tabDraggedOut(id: id, to: point) }

        sidebar.faviconProvider = { [weak self] address in
            self?.faviconStore.image(forAddress: address)
        }
    }

    /// Navigation buttons and the link bubble follow the selected tab.
    func updateTabChrome(for tab: BrowserTab) {
        toolbar.navigationControls.update(
            canGoBack: tab.webView.canGoBack,
            canGoForward: tab.webView.canGoForward,
            isLoading: tab.webView.isLoading
        )
        if let showing = linkStatus.tabID, showing != tab.id {
            linkStatus.hide()
        }
    }

    /// The tab's address changed: show the host's cached icon right away
    /// (the page reports its own once parsed) and drop a stale link bubble.
    func tabURLChanged(_ tab: BrowserTab) {
        let cached = faviconStore.image(for: tab.webView.url)
        if tab.favicon !== cached {
            tab.favicon = cached
        }
        if linkStatus.tabID == tab.id {
            linkStatus.hide()
        }
    }

    func receiveFavicons(_ body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame, let pageURL = tab.webView.url,
              let key = BrowserFaviconSelection.key(for: pageURL)
        else { return }
        let entries = (body["icons"] as? [[String: Any]] ?? []).prefix(32)
        let candidates = entries.compactMap { entry -> BrowserFaviconCandidate? in
            guard let href = entry["href"] as? String, let rel = entry["rel"] as? String else { return nil }
            return BrowserFaviconCandidate(
                href: href,
                rel: rel,
                sizes: entry["sizes"] as? String,
                type: entry["type"] as? String,
                base: pageURL
            )
        }
        faviconStore.resolve(pageURL: pageURL, candidates: candidates) { [weak self, weak tab] image in
            guard let self, let tab,
                  BrowserFaviconSelection.key(for: tab.webView.url) == key,
                  tab.favicon !== image
            else { return }
            tab.favicon = image
            self.metadataChanged(tab)
        }
    }

    func receiveLinkHover(_ body: [String: Any], tab: BrowserTab, frame: WKFrameInfo) {
        guard frame.isMainFrame, tab.id == selectedTab?.id else { return }
        let url = (body["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            linkStatus.hide()
        } else {
            linkStatus.show(url, tabID: tab.id)
        }
    }

    // MARK: - Back/forward list

    func historyMenu(_ direction: BrowserNavigationControls.Direction) -> NSMenu? {
        guard let tab = selectedTab else { return nil }
        let list = tab.webView.backForwardList
        let items = direction == .back ? Array(list.backList.reversed()) : list.forwardList
        guard !items.isEmpty else { return nil }
        let menu = NSMenu(title: direction == .back ? "Back" : "Forward")
        menu.autoenablesItems = false
        for entry in items.prefix(20) {
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let item = NSMenuItem(
                title: title.isEmpty ? entry.url.absoluteString : title,
                action: #selector(goToHistoryItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry
            item.toolTip = entry.url.absoluteString
            item.image = faviconStore.image(for: entry.url) ?? Self.placeholderMenuIcon
            menu.addItem(item)
        }
        return menu
    }

    @objc func goToHistoryItem(_ sender: NSMenuItem) {
        guard let tab = selectedTab, let item = sender.representedObject as? WKBackForwardListItem else { return }
        tab.pendingURL = item.url.absoluteString
        tab.webView.go(to: item)
    }

    private static var placeholderMenuIcon: NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
