import AppKit

/// A normal window shows one Space at a time (`currentSpaceID`); its other
/// Spaces' tabs stay alive, hidden, each Space remembering its selection.
/// ⌃1…⌃9, ⌥⌘←/⌥⌘→, the Spaces menu, a two-finger swipe on the rail and the
/// CLI's `space` switch it. Private and pop-up windows have no Spaces.
extension BrowserWindowController {
    // MARK: - Switching

    /// Every Space in display order.
    var spaceOrder: [UUID] {
        spaces.spaces.map(\.id)
    }

    /// Shows Space `id`: the window's data context becomes the Space's
    /// profile's, the tab list its tabs, and it selects `tabID` (one of
    /// its tabs), else its remembered tab, else its most recently used
    /// one; an empty Space opens a start-page Today tab. No-op in a window
    /// without Spaces or for an unknown Space.
    func switchToSpace(_ id: UUID, selecting tabID: UUID? = nil, focus: Bool = true) {
        guard hasSpaces, let space = spaces.space(id: id) else { return }
        let leaving = selectedTab
        if id != currentSpaceID {
            setCurrentSpace(space)
        }
        let target = tabID.flatMap { wanted in visibleTabs.contains { $0.id == wanted } ? wanted : nil }
            ?? BrowserSpaceSwitch.selection(
                remembered: spaceSelections[id],
                tabs: visibleTabs.map { (id: $0.id, lastActive: $0.lifecycle.lastActiveAt) }
            )
        if let target, let index = visibleTabs.firstIndex(where: { $0.id == target }) {
            selectedIndex = index
            showSelectedTab(leaving: leaving, focus: focus)
        } else {
            if let leaving {
                previousSelectedTabID = leaving.id
                leaving.lifecycle.lastActiveAt = manager.tabSleeper.now()
                leaving.webView.isHidden = true
                removeWakeSnapshot(leaving)
            }
            if focus {
                newTab(focusAddress: true)
            } else {
                selectTab(id: newTab(select: false).id, focus: false)
            }
        }
        if isSidebarVisible {
            sidebar.refresh()
        }
        saveSession()
    }

    /// ⌥⌘→ / ⌥⌘← and the rail's swipe: the next (`step` 1) or previous
    /// (-1) Space, wrapping around.
    func switchToNeighborSpace(step: Int) {
        guard hasSpaces,
              let id = BrowserSpaceSwitch.neighbor(of: currentSpaceID, step: step, in: spaceOrder),
              id != currentSpaceID
        else { return }
        switchToSpace(id)
    }

    /// ⌃1…⌃9: Space `number` (1-based, display order).
    func switchToSpace(number: Int) {
        guard hasSpaces, let id = BrowserSpaceSwitch.space(number: number, in: spaceOrder) else { return }
        switchToSpace(id)
    }

    // MARK: - Spaces changing under the window

    /// The Spaces changed (created, renamed, reordered, deleted, given
    /// another profile, pins or favorites edited). A window on a deleted
    /// Space shows another one of its profile (else the first); a tab
    /// whose pin or favorite is gone becomes a Today tab; tabs of a deleted
    /// Space close onto Recently Closed; a tab whose Space now uses another
    /// profile comes back in that profile (its page reloads there,
    /// back/forward list kept), since a web view keeps its data store for
    /// life.
    func spacesChanged() {
        guard hasSpaces, !tabs.isEmpty else { return }
        if let current = currentSpaceID, spaces.space(id: current) == nil,
           let next = spaces.firstSpace(ofProfile: profileID) ?? spaces.spaces.first
        {
            switchToSpace(next.id, focus: false)
        }
        var targets: [UUID: BrowserPinLinks.Targets] = [:]
        for tab in tabs where tab.origin != .today {
            guard let spaceID = tab.spaceID else { continue }
            let spaceTargets = targets[spaceID] ?? spaces.linkTargets(inSpace: spaceID)
            targets[spaceID] = spaceTargets
            tab.origin = BrowserPinLinks.validated(tab.origin, in: spaceTargets)
        }
        for tab in tabs where tab.spaceID.flatMap(spaces.space(id:)) == nil {
            closeTab(id: tab.id)
        }
        for tab in tabs {
            guard let space = tab.spaceID.flatMap(spaces.space(id:)),
                  manager.context(for: space.profileID) !== tab.dataContext
            else { continue }
            reopenInItsSpace(tab)
        }
        if let current = currentSpaceID.flatMap(spaces.space(id:)),
           manager.context(for: current.profileID) !== dataContext
        {
            let selected = selectedTab?.id
            setCurrentSpace(current)
            selectedIndex = visibleTabs.firstIndex { $0.id == selected } ?? 0
            updateTabStrip()
            updateChrome()
        }
        saveSession()
    }

    /// Replaces `tab` with a not yet loaded copy made in its Space's
    /// current profile, at the same place; a selected tab stays selected.
    private func reopenInItsSpace(_ tab: BrowserTab) {
        let index = tabs.filter { $0.spaceID == tab.spaceID }.firstIndex { $0 === tab }
        let wasSelected = tab.id == selectedTab?.id
        var state = tab.state
        state.origin = .today
        let copy = addRestoredTab(state, at: index)
        // The copy takes over the link (while its pin or favorite is still
        // the Space's) before the original goes and the session is saved.
        copy.origin = BrowserPinLinks.originAfterMove(
            tab.origin,
            into: copy.spaceID.map(spaces.linkTargets(inSpace:)) ?? BrowserPinLinks.Targets(),
            live: tabs.filter { $0 !== tab && $0 !== copy }.map(\.origin)
        )
        copy.linkLanding = copy.origin == .today ? nil : tab.linkLanding
        refreshVisibleTabs()
        if wasSelected {
            selectTab(id: copy.id, focus: false)
        }
        detachTab(tab)
        discardTab(tab)
        saveSession()
    }

    /// Profile `profileID` is being deleted: a window on one of its Spaces
    /// shows another profile's Space (one it has tabs in, else the first),
    /// and every tab of the profile closes without going onto Recently
    /// Closed (its data goes with it). The caller closes a window that held
    /// only the profile's tabs instead.
    func closeTabs(ofProfile profileID: UUID) {
        guard hasSpaces else { return }
        if self.profileID == profileID {
            let others = spaces.spaces.filter { $0.profileID != profileID }
            let used = others.first { space in tabs.contains { $0.spaceID == space.id } }
            if let other = used ?? others.first {
                switchToSpace(other.id, focus: false)
            }
        }
        for tab in tabs where tab.dataContext.profileID == profileID {
            detachTab(tab)
            discardTab(tab)
        }
    }
}
