import AppKit

extension BrowserWindowController {
    // MARK: - Command Bar

    /// Puts the Command Bar over the window's content and gives it its
    /// sources and actions.
    func installCommandBar() {
        let view = commandBar.view
        rootView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: rootView.topAnchor),
            view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        commandBar.makeInput = { [weak self] text, mode, siteSearch in
            self?.commandBarInput(text, mode: mode, siteSearch: siteSearch)
                ?? BrowserCommandBarInput(query: text, mode: mode, siteSearch: siteSearch)
        }
        commandBar.onChoose = { [weak self] row, mode in self?.chooseCommandBarRow(row, mode: mode) }
        commandBar.onDismiss = { [weak self] in self?.focusPage() }
    }

    /// ⌘T (empty; Return opens a new Today tab), ⌘L (the selected tab's
    /// address; Return navigates it) and ⇧⌘P (`/` actions). The same mode
    /// again closes it (`toggles`).
    func showCommandBar(_ mode: BrowserCommandBarMode, toggles: Bool = true) {
        if isPopup {
            guard mode != .editCurrent else {
                // ⌘L edits the pop-up's own address.
                toolbar.focusAddress(selectAll: true)
                return
            }
            // A pop-up window has no tabs to open into.
            let target = manager.windowForNewTabs(from: self).window
            manager.present(target)
            target.showCommandBar(mode, toggles: toggles)
            return
        }
        if commandBar.isOpen, commandBar.mode == mode {
            guard toggles else { return }
            commandBar.close()
            focusPage()
            return
        }
        addressBar.close()
        cancelRecentTabs()
        rootView.addSubview(commandBar.view, positioned: .above, relativeTo: nil)
        switch mode {
        case .newTab:
            commandBar.open(mode: mode, text: "", selectAll: false)
        case .editCurrent:
            let address = selectedTab.flatMap { tab in
                tab.isStartPage ? nil : tab.failedURL ?? tab.webView.url?.absoluteString
            } ?? ""
            commandBar.open(mode: mode, text: address, selectAll: true)
        case .actions:
            commandBar.open(mode: mode, text: "/", selectAll: false)
        }
    }

    /// What the Command Bar searches for `text`: the window's other tabs
    /// (every Space, most recent first), the Space's pins and the
    /// profile's favorites, History (a private window's in-memory pages),
    /// the Spaces, the registry's enabled actions and the settings pages.
    func commandBarInput(
        _ text: String,
        mode: BrowserCommandBarMode,
        siteSearch: BrowserSearchEngineID?
    ) -> BrowserCommandBarInput {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedID = selectedTab?.id
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let openTabs = recentTabs.recent(among: tabs.map(\.id).filter { $0 != selectedID }, limit: tabs.count)
            .compactMap { id -> BrowserCommandBarInput.Tab? in
                guard let tab = byID[id], !tab.isStartPage, let url = tab.item.url?.absoluteString else { return nil }
                let otherSpace = tab.spaceID != currentSpaceID
                    ? tab.spaceID.flatMap(spaces.space(id:)).map(BrowserSpacesMenu.spaceTitle)
                    : nil
                return BrowserCommandBarInput.Tab(id: tab.id, title: tab.displayTitle, url: url, otherSpace: otherSpace)
            }
        let searchesPages = !query.isEmpty && !query.hasPrefix("/") && siteSearch == nil
        let history: [BrowserHistoryPage] = searchesPages
            ? (kind.suggestsHistory
                ? dataContext.history.suggestionCandidates(for: query)
                : dataContext.sessionVisits.candidates(for: query))
            : []
        let keymap = settingsStore.settings.keymap
        let context = BrowserCommandContext(manager: manager, controller: self)
        let actions = BrowserAppCommand.all.compactMap { command -> BrowserCommandBarInput.Action? in
            guard command.inCommandBar, command.systemAction == nil else { return nil }
            let state = command.state(context)
            guard state.isEnabled else { return nil }
            return BrowserCommandBarInput.Action(
                id: command.id,
                title: state.title ?? command.title,
                synonyms: command.synonyms,
                shortcut: keymap.shortcut(for: command.id)?.display ?? "",
                symbol: command.symbol
            )
        }
        return BrowserCommandBarInput(
            query: text,
            mode: mode,
            siteSearch: siteSearch,
            tabs: openTabs,
            pins: searchesPages ? (pinSpaceID.map { spaces.pins(inSpace: $0) } ?? []) : [],
            favorites: searchesPages && hasSpaces ? spaces.favorites(ofProfile: profileID) : [],
            history: history,
            spaces: hasSpaces
                ? spaces.spaces.map { .init(id: $0.id, name: BrowserSpacesMenu.spaceTitle($0), isCurrent: $0.id == currentSpaceID) }
                : [],
            actions: actions,
            searchEngines: settingsStore.settings.searchEngines
        )
    }

    /// Runs a chosen row. Addresses and searches open in a new Today tab of
    /// the current Space (⌘T) or the selected tab (⌘L); nothing is written
    /// to History here (navigation records it, never in a private window).
    func chooseCommandBarRow(_ row: BrowserCommandBarRow, mode: BrowserCommandBarMode) {
        let newTab = mode != .editCurrent
        switch row.target {
        case let .url(address):
            openAddress(address, typed: true, newTab: newTab)
        case let .search(engineID, query):
            guard let url = settingsStore.settings.searchEngines.engine(id: engineID)?.searchURL(for: query) else {
                return
            }
            openAddress(url.absoluteString, typed: false, newTab: newTab)
        case let .tab(id):
            selectTab(id: id, focus: true)
        case let .pin(id):
            openPin(id)
        case let .favorite(id):
            openFavorite(id)
        case let .space(id):
            switchToSpace(id)
        case .startPage:
            self.newTab()
        case let .command(id):
            id.command.perform(in: BrowserCommandContext(manager: manager, controller: self))
            focusPageIfUnfocused()
        case let .settings(page):
            manager.showSettings(page: page)
            focusPageIfUnfocused()
        }
    }

    /// After a row that doesn't move focus itself, the page gets it back
    /// (closing the bar left the window with none).
    private func focusPageIfUnfocused() {
        guard let window, window.firstResponder == nil || window.firstResponder === window else { return }
        focusPage()
    }
}
