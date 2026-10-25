import AppKit

extension BrowserWindowController {
    // MARK: - Moving tabs between windows

    /// Window ▸ Move Tab to New Window and Vimium `W`: the selected tab.
    func moveSelectedTabToNewWindow() {
        guard let tab = selectedTab else { return }
        moveTabToNewWindow(id: tab.id)
    }

    /// The live tab moves into a new window cascaded from this one; this
    /// window keeps its other tabs or closes when it was the last one.
    func moveTabToNewWindow(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        manager.moveTabToNewWindow(tab, from: self)
    }

    /// Whether this window's tab list takes a dragged tab: its own (a
    /// reorder within the current Space) or one from a window it can move
    /// from (`BrowserTabMoveRule`: the tab's context is the current
    /// Space's).
    func canAcceptDroppedTab(id: UUID) -> Bool {
        if visibleTabs.contains(where: { $0.id == id }) { return !isPopup }
        guard let (source, tab) = manager.tab(id: id), source !== self else { return false }
        return manager.canMoveTab(tab, from: source, to: self)
    }

    /// A tab dropped into gap `insertion` of this window's tab list (0 is
    /// before the first tab of the current Space): its own tab moves there,
    /// another window's tab moves in as a Today tab of the current Space,
    /// selected. Returns false when the tab can't come here.
    @discardableResult
    func dropTab(id: UUID, at insertion: Int) -> Bool {
        if let from = visibleTabs.firstIndex(where: { $0.id == id }) {
            moveTab(id: id, toIndex: BrowserTabReorder.moveIndex(forInsertion: insertion, from: from))
            return true
        }
        guard let (source, tab) = manager.tab(id: id), source !== self,
              manager.canMoveTab(tab, from: source, to: self)
        else {
            return false
        }
        manager.moveTab(tab, from: source, to: self, at: insertion, select: true)
        return true
    }

    /// The tab's drag session ended where no window took it, at
    /// `screenPoint`: it opens in a new window there.
    func tabDraggedOut(id: UUID, to screenPoint: NSPoint) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        manager.moveTabToNewWindow(tab, from: self, droppedAt: screenPoint)
    }

    /// The find query that travels with `tab` when it leaves: the open find
    /// bar's query while it is the selected tab.
    func findQuery(carriedBy tab: BrowserTab) -> String? {
        guard tab.id == selectedTab?.id, !findBar.isHidden, !findQuery.isEmpty else { return nil }
        return findQuery
    }

    /// Opens the find bar on the newly arrived tab with the query it
    /// brought and finds it again.
    func carryFind(_ query: String?) {
        guard let query, !query.isEmpty else { return }
        showFindBar()
        findBar.query = query
        findQuery = query
        lastFindQuery = query
        performFind(backwards: false, updateResult: true)
    }

    @objc func moveTabToNewWindowFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        moveTabToNewWindow(id: id)
    }
}
