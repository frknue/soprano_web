import AppKit

/// Live pinned and favorite tabs (Arc's model), per window: a pin of the
/// current Space or a favorite of its profile has at most one live tab in
/// the window (`BrowserTab.origin`). Clicking the pin selects it or opens
/// one; ⌘W unloads it back to the pin; a tab whose page left the pin's
/// address shows "/" and its pin's icon resets it. Windows without Spaces
/// (private, pop-up) open pins as plain tabs.
extension BrowserWindowController {
    // MARK: - Links

    /// The address `tab`'s pin or favorite points at; nil for a Today tab
    /// or a link that no longer resolves.
    func linkedURL(of tab: BrowserTab) -> String? {
        switch tab.origin {
        case .today:
            return nil
        case let .pinned(id):
            return tab.spaceID.flatMap { spaces.pinTree(inSpace: $0).node(id: id)?.pin?.url }
        case let .favorite(id):
            return spaces.favorites(ofProfile: tab.dataContext.profileID).first { $0.id == id }?.url
        }
    }

    /// The page the tab shows (or will show once loaded); nil on the start
    /// page.
    func pageAddress(of tab: BrowserTab) -> String? {
        tab.item.url?.absoluteString
    }

    /// The "/" mark: a linked tab whose page left its pin's address.
    func isAway(_ tab: BrowserTab) -> Bool {
        guard let pinURL = linkedURL(of: tab) else { return false }
        return BrowserPinLinks.isAway(pageAddress(of: tab), from: pinURL)
    }

    /// What the tab strip and the rail draw for `tab`.
    func tabItem(_ tab: BrowserTab) -> BrowserTabItem {
        var item = tab.item
        item.isLinked = hasSpaces && tab.origin != .today
        item.isAway = item.isLinked && isAway(tab)
        return item
    }

    /// The window's live tab for a pin of the current Space, or for a
    /// favorite of the current Space's profile (in any of its Spaces).
    func liveTab(for origin: BrowserTabOrigin) -> BrowserTab? {
        switch origin {
        case .today:
            return nil
        case .pinned:
            return tabs.first { $0.origin == origin && $0.spaceID == currentSpaceID }
        case .favorite:
            return tabs.first { $0.origin == origin && $0.dataContext.profileID == profileID }
        }
    }

    // MARK: - Opening

    /// A pin's row: its live tab, else a new tab linked to it, selected.
    func openPin(_ id: UUID) {
        guard let pin = currentPinTree.node(id: id)?.pin else { return }
        guard hasSpaces else {
            newTab(url: pin.url)
            return
        }
        if let tab = liveTab(for: .pinned(id)) {
            selectTab(id: tab.id, focus: true)
        } else {
            openLinkedTab(url: pin.url, origin: .pinned(id))
        }
    }

    /// A favorite: its live tab (brought into the current Space when it
    /// was opened in another Space of the profile), else a new tab linked
    /// to it, selected.
    func openFavorite(_ id: UUID) {
        guard let favorite = spaces.favorites(ofProfile: profileID).first(where: { $0.id == id }) else { return }
        guard hasSpaces else {
            newTab(url: favorite.url)
            return
        }
        if let tab = liveTab(for: .favorite(id)) {
            if tab.spaceID != currentSpaceID, let previous = tab.spaceID {
                if spaceSelections[previous] == tab.id {
                    spaceSelections[previous] = nil
                }
                tab.spaceID = currentSpaceID
                refreshVisibleTabs()
            }
            selectTab(id: tab.id, focus: true)
        } else {
            openLinkedTab(url: favorite.url, origin: .favorite(id))
        }
    }

    /// A new selected tab of the current Space linked to a pin or favorite.
    private func openLinkedTab(url: String, origin: BrowserTabOrigin) {
        let tab = makeTab(context: dataContext)
        tab.spaceID = currentSpaceID
        tab.origin = origin
        attachTab(tab, select: false)
        navigate(tab, to: url)
        selectTab(id: tab.id, focus: true)
        saveSession()
    }

    /// Clicking a pin's or favorite's icon: its live tab goes back to the
    /// pinned address and is selected; `keepingPage` (⌘-click) first opens
    /// the page it had moved on to in a new Today tab, which is selected
    /// instead. Without a live tab it opens like the row.
    func pinIconPressed(_ origin: BrowserTabOrigin, keepingPage: Bool) {
        guard let tab = liveTab(for: origin) else {
            switch origin {
            case let .pinned(id): openPin(id)
            case let .favorite(id): openFavorite(id)
            case .today: break
            }
            return
        }
        resetLinkedTab(tab, keepingPage: keepingPage)
    }

    /// Sends a linked tab back to its pin's address. `keepingPage` keeps
    /// the page it was on in a new Today tab of its Space, selected.
    func resetLinkedTab(_ tab: BrowserTab, keepingPage: Bool) {
        guard let pinURL = linkedURL(of: tab) else { return }
        let away = isAway(tab)
        let page = pageAddress(of: tab)
        if tab.spaceID != currentSpaceID, tab.origin.favoriteID != nil {
            tab.spaceID = currentSpaceID
            refreshVisibleTabs()
        }
        if away {
            navigate(tab, to: pinURL)
        }
        if keepingPage, away, let page {
            newTab(url: page)
        } else {
            selectTab(id: tab.id, focus: true)
        }
        updateTabStrip()
        saveSession()
    }

    // MARK: - Closing

    /// ⌘W on a pinned or favorite tab: the tab goes away and the pin
    /// stays; it does not go onto Recently Closed. A Space left without
    /// tabs shows a start tab, and so does a window losing its last tab.
    func unloadLinkedTab(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tabs.count == 1 {
            newTab(select: true)
        }
        detachTab(tab)
        discardTab(tab)
        updateTabStrip()
    }

    // MARK: - Tab and pin menus

    /// Replace Pin with Current Page: the tab's pin (or favorite) now
    /// points at its page and title.
    func replaceLink(with tab: BrowserTab) {
        guard let address = pageAddress(of: tab) else { return }
        switch tab.origin {
        case .today:
            return
        case let .pinned(id):
            guard let spaceID = tab.spaceID else { return }
            spaces.editPin(id, title: tab.displayTitle, url: address, inSpace: spaceID)
        case let .favorite(id):
            spaces.replaceFavorite(id, url: address, title: tab.displayTitle, ofProfile: tab.dataContext.profileID)
        }
        updateTabStrip()
        saveSession()
    }

    /// Pin Tab: a new pin first in the current Space's top level, and the
    /// tab becomes its live tab (a favorite tab leaves Favorites).
    func pinTab(_ tab: BrowserTab) {
        guard hasSpaces, let spaceID = tab.spaceID, let address = pageAddress(of: tab), !tab.isStartPage,
              let pin = spaces.addPin(url: address, title: tab.displayTitle, inSpace: spaceID)
        else {
            NSSound.beep()
            return
        }
        let previous = tab.origin
        tab.origin = .pinned(pin.id)
        if case let .favorite(id) = previous {
            spaces.removeFavorite(id, ofProfile: tab.dataContext.profileID)
        }
        linksChanged()
    }

    /// Unpin Tab: the pin goes; its tab stays open as a Today tab.
    func unpinTab(_ tab: BrowserTab) {
        guard case let .pinned(id) = tab.origin, let spaceID = tab.spaceID else { return }
        tab.origin = .today
        spaces.removePin(id, inSpace: spaceID)
        linksChanged()
    }

    /// Add to Favorites: a new favorite of the tab's profile (at most
    /// `BrowserFavorites.limit`) and the tab becomes its live tab (a pinned
    /// tab's pin goes, as in Arc).
    func addTabToFavorites(_ tab: BrowserTab) {
        guard hasSpaces, let address = pageAddress(of: tab), !tab.isStartPage,
              let favorite = spaces.addFavorite(url: address, title: tab.displayTitle, ofProfile: tab.dataContext.profileID)
        else {
            NSSound.beep()
            return
        }
        let previous = tab.origin
        tab.origin = .favorite(favorite.id)
        if case let .pinned(id) = previous, let spaceID = tab.spaceID {
            spaces.removePin(id, inSpace: spaceID)
        }
        linksChanged()
    }

    /// Remove from Favorites: the favorite goes; its tab stays open as a
    /// Today tab.
    func removeTabFromFavorites(_ tab: BrowserTab) {
        guard case let .favorite(id) = tab.origin else { return }
        tab.origin = .today
        spaces.removeFavorite(id, ofProfile: tab.dataContext.profileID)
        linksChanged()
    }

    /// Whether the tab's profile can take another favorite.
    func canAddFavorite(for tab: BrowserTab) -> Bool {
        spaces.favorites(ofProfile: tab.dataContext.profileID).count < BrowserFavorites.limit
    }

    /// A tab's link changed: the order, lists and session follow.
    private func linksChanged() {
        refreshVisibleTabs()
        updateTabStrip()
        updateChrome()
        saveSession()
    }

    /// Removes a pin or favorite from the rail's menus; its live tab stays
    /// as a Today tab (`spacesChanged`).
    func removeFavorite(_ id: UUID) {
        spaces.removeFavorite(id, ofProfile: profileID)
    }
}
