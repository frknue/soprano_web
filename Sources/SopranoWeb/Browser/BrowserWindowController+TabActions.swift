import AppKit

extension BrowserWindowController {
    // MARK: - Tab context menu

    /// Reload, Duplicate, Mute, Copy Link, Keep This Site Awake, Pin Tab /
    /// Unpin Tab and Add to / Remove from Favorites (with Spaces), Move Tab
    /// to New Window, the close actions and Reopen Closed Tab for one tab
    /// of the current Space. `closeAfterTitle` names the run after it:
    /// "Close Tabs Below" in the rail, "… to the Right" in the strip. A
    /// split's row gets the split's menu (`splitContextMenu`).
    func tabContextMenu(for id: UUID, closeAfterTitle: String) -> NSMenu? {
        if split(id: id) != nil {
            return splitContextMenu(for: id)
        }
        guard let index = visibleTabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = visibleTabs[index]
        let menu = NSMenu(title: "Tab")
        menu.autoenablesItems = false

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled
            menu.addItem(item)
        }

        let hasPage = !tab.isStartPage && tab.item.url != nil
        add("Reload", #selector(reloadTabFromMenu(_:)))
        add("Duplicate", #selector(duplicateTabFromMenu(_:)), enabled: tab.isStartPage || tab.webView.url != nil)
        add(tab.isMuted ? "Unmute Tab" : "Mute Tab", #selector(toggleMuteFromMenu(_:)))
        add("Copy Link", #selector(copyTabLinkFromMenu(_:)), enabled: hasPage)
        let awakeHost = keepAwakeKey(for: tab)
        add("Keep This Site Awake", #selector(toggleKeepAwakeFromMenu(_:)), enabled: awakeHost != nil)
        menu.items.last?.state = awakeHost.map(tab.dataContext.sitePermissions.keepsAwake(host:)) == true ? .on : .off
        menu.addItem(.separator())
        if hasSpaces {
            addLinkItems(for: tab, hasPage: hasPage, add: add)
            menu.addItem(.separator())
        }
        add("Move Tab to New Window", #selector(moveTabToNewWindowFromMenu(_:)))
        if allowsSplits, !isShown(tab) {
            add("Open in Split View", #selector(openInSplitFromMenu(_:)), enabled: !(shownSplit?.isFull ?? false))
        }
        menu.addItem(.separator())
        add("Close Tab", #selector(closeTabFromMenu(_:)))
        add("Close Other Tabs", #selector(closeOtherTabsFromMenu(_:)), enabled: !otherClosable(keeping: id).isEmpty)
        add(closeAfterTitle, #selector(closeTabsAfterFromMenu(_:)), enabled: !closable(after: id).isEmpty)
        menu.addItem(.separator())
        add("Reopen Closed Tab", #selector(reopenClosedTabFromMenu(_:)), enabled: canReopenClosedTab)
        return menu
    }

    /// A tab's mute button; a split's mutes every pane, or unmutes them all
    /// when every pane is muted.
    func toggleMute(id: UUID) {
        if let split = split(id: id) {
            let panes = split.tabIDs.compactMap { tabID in tabs.first { $0.id == tabID } }
            let mute = !panes.allSatisfy(\.isMuted)
            for pane in panes where pane.isMuted != mute {
                toggleMute(pane)
            }
            return
        }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        toggleMute(tab)
    }

    /// Pin Tab / Unpin Tab, Add to / Remove from Favorites, and for a
    /// linked tab whose page moved on: back to its pinned page, or Replace
    /// Pin (Favorite) with Current Page.
    private func addLinkItems(
        for tab: BrowserTab,
        hasPage: Bool,
        add: (String, Selector, Bool) -> Void
    ) {
        let away = isAway(tab)
        switch tab.origin {
        case .today:
            add("Pin Tab", #selector(pinTabFromMenu(_:)), hasPage)
            add("Add to Favorites", #selector(addToFavoritesFromMenu(_:)), hasPage && canAddFavorite(for: tab))
        case .pinned:
            add("Unpin Tab", #selector(unpinTabFromMenu(_:)), true)
            add("Add to Favorites", #selector(addToFavoritesFromMenu(_:)), hasPage && canAddFavorite(for: tab))
            add("Back to Pinned Page", #selector(resetLinkedTabFromMenu(_:)), away)
            add("Replace Pin with Current Page", #selector(replaceLinkFromMenu(_:)), away)
        case .favorite:
            add("Pin Tab", #selector(pinTabFromMenu(_:)), hasPage)
            add("Remove from Favorites", #selector(removeFromFavoritesFromMenu(_:)), true)
            add("Back to Favorite Page", #selector(resetLinkedTabFromMenu(_:)), away)
            add("Replace Favorite with Current Page", #selector(replaceLinkFromMenu(_:)), away)
        }
    }

    /// The tabs Close Other Tabs closes: the current Space's Today tabs
    /// but `id` (every other tab in a window without Spaces); pinned and
    /// favorite tabs stay.
    private func otherClosable(keeping id: UUID) -> [UUID] {
        visibleTabs.filter { $0.id != id && (!hasSpaces || $0.origin == .today) }.map(\.id)
    }

    /// The Today tabs after `id` (below it in the rail, right of it in the
    /// strip).
    private func closable(after id: UUID) -> [UUID] {
        guard let index = visibleTabs.firstIndex(where: { $0.id == id }) else { return [] }
        return visibleTabs[(index + 1)...].filter { !hasSpaces || $0.origin == .today }.map(\.id)
    }

    /// Closes the current Space's other Today tabs and selects `id`.
    func closeOtherTabs(keeping id: UUID) {
        guard visibleTabs.contains(where: { $0.id == id }) else { return }
        closeTabs(otherClosable(keeping: id), thenSelect: id)
    }

    /// Closes the current Space's Today tabs after `id` (below it in the
    /// rail, right of it in the strip). The selection stays, or moves to
    /// `id` when it was closed.
    func closeTabs(after id: UUID) {
        let closing = closable(after: id)
        guard !closing.isEmpty else { return }
        let selected = selectedTab.map(\.id).flatMap { closing.contains($0) ? nil : $0 } ?? id
        closeTabs(closing, thenSelect: selected)
    }

    /// Closes `ids` as ⌘W would one by one (each onto Recently Closed with
    /// its place in its Space, Today tabs into the Archive), with one
    /// Archive write and the window's UI work done once (`detachTabs`),
    /// then selects `selection`. The caller keeps a tab open.
    private func closeTabs(_ ids: [UUID], thenSelect selection: UUID) {
        selectTab(id: selection, focus: false)
        // Last first, as one-by-one closing went: each tab's index in its
        // Space counts only the tabs before it.
        let closing = ids.reversed().compactMap { id in tabs.first { $0.id == id } }
        var archived: [BrowserArchiveEntry] = []
        for tab in closing {
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
            if let archive = archiveEntry(for: tab, reason: .manual) {
                archived.append(archive)
            }
        }
        manager.archive.archive(archived)
        detachTabs(closing)
        closing.forEach(discardTab)
        selectTab(id: selection, focus: true)
    }

    private func menuTab(_ sender: NSMenuItem) -> BrowserTab? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return tabs.first { $0.id == id }
    }

    @objc func reloadTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        reload(tab)
    }

    @objc func duplicateTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        duplicateTab(id: tab.id)
    }

    @objc func toggleMuteFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        toggleMute(tab)
    }

    @objc func copyTabLinkFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender), let url = tab.item.url?.absoluteString else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    @objc func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeTab(id: tab.id, archive: true)
    }

    @objc func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeOtherTabs(keeping: tab.id)
    }

    @objc func closeTabsAfterFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        closeTabs(after: tab.id)
    }

    @objc func reopenClosedTabFromMenu(_ sender: NSMenuItem) {
        reopenClosedTab()
    }

    @objc func pinTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        pinTab(tab)
    }

    @objc func unpinTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        unpinTab(tab)
    }

    @objc func addToFavoritesFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        addTabToFavorites(tab)
    }

    @objc func removeFromFavoritesFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        removeTabFromFavorites(tab)
    }

    @objc func resetLinkedTabFromMenu(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        resetLinkedTab(tab, keepingPage: false)
    }
}
