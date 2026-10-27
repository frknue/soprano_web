import AppKit
import WebKit

/// Split View (Arc's): 2–4 tabs of one Space side by side in the page area,
/// resized by the dividers between them, shown as one rail row (the panes'
/// favicons) and one strip item (`BrowserSplit`, `BrowserTabRows`). The
/// focused pane is the selected tab: the toolbar, every command, Vimium and
/// the CLI act on it; clicking into another pane focuses it. Panes keep
/// their origin (a pinned or favorite pane unloads to its pin when
/// closed; Today panes archive like any Today tab) and are never idle
/// while on screen (`isShown`). ⌃⇧= adds a pane (a new tab with the
/// Command Bar), ⌃⇧- closes the focused one, ⌃⇧1…4 focus one, ⌥-click
/// on a link opens it in a new pane, a tab dropped near a pane's left or
/// right edge joins there. A Peek opens over the whole page area (the
/// split included) and belongs to the focused pane: focusing another pane
/// closes it. A split ends when one pane is left; pop-up and Little Arc
/// windows have none.
extension BrowserWindowController {
    // MARK: - Lookup

    func split(containing tabID: UUID) -> BrowserSplit? {
        splits.first { $0.contains(tabID) }
    }

    func split(id: UUID) -> BrowserSplit? {
        splits.first { $0.id == id }
    }

    /// The split on screen: the selected tab's.
    var shownSplit: BrowserSplit? {
        selectedTab.flatMap { split(containing: $0.id) }
    }

    /// What the page area shows: the shown split's panes, left to right,
    /// else the selected tab.
    var shownTabs: [BrowserTab] {
        guard let selected = selectedTab else { return [] }
        return pageTabs(of: selected)
    }

    /// The tabs on screen with `tab`: its split's panes (left to right), or
    /// the tab alone.
    func pageTabs(of tab: BrowserTab) -> [BrowserTab] {
        guard let split = split(containing: tab.id) else { return [tab] }
        let panes = split.tabIDs.compactMap { id in tabs.first { $0.id == id } }
        return panes.isEmpty ? [tab] : panes
    }

    /// The selected tab or a pane of the split on screen.
    func isShown(_ tab: BrowserTab) -> Bool {
        tab.id == selectedTab?.id || shownSplit?.contains(tab.id) == true
    }

    /// A pane of the split on screen other than the focused one.
    func isVisiblePane(_ tab: BrowserTab) -> Bool {
        tab.id != selectedTab?.id && shownSplit?.contains(tab.id) == true
    }

    /// Whether this window has split views (not a pop-up or Little Arc).
    var allowsSplits: Bool {
        role == .normal
    }

    private func replaceSplit(_ split: BrowserSplit) {
        guard let index = splits.firstIndex(where: { $0.id == split.id }) else { return }
        splits[index] = split
    }

    // MARK: - Adding panes

    /// ⌃⇧= and the CLI's `split [url]`: a new Today tab (`url`, else the
    /// start page) as a pane right of the focused one, focused; with
    /// `commandBar` the Command Bar opens on it (Return navigates the
    /// pane). Nil when the split on screen is full or the window has no
    /// splits.
    @discardableResult
    func addSplitPane(url: String? = nil, commandBar: Bool) -> BrowserTab? {
        guard allowsSplits, let anchor = selectedTab, !(shownSplit?.isFull ?? false) else { return nil }
        let tab = makeTab(context: anchor.dataContext)
        tab.spaceID = anchor.spaceID
        let index = tabs.filter { $0.spaceID == anchor.spaceID }.firstIndex { $0 === anchor }.map { $0 + 1 }
        attachTab(tab, at: index, select: false)
        if let url, !url.isEmpty {
            navigate(tab, to: url)
        } else {
            loadStartPage(tab)
        }
        addPane(tab, to: anchor, at: nil, focus: true)
        if commandBar {
            showCommandBar(.editCurrent, toggles: false)
        }
        return tab
    }

    /// Puts `tab` into `anchor`'s split at pane `index` (nil: right of
    /// `anchor`), or makes a split of the two; a tab already in a split
    /// leaves it first. Both must be tabs of the current Space here. The
    /// split's Today panes move next to each other in the Space's order.
    /// `focus` focuses `tab`; otherwise the selection stays. Returns false
    /// (nothing changes) when the split is full or the tabs can't pair.
    @discardableResult
    func addPane(_ tab: BrowserTab, to anchor: BrowserTab, at index: Int?, focus: Bool) -> Bool {
        guard allowsSplits, tab !== anchor,
              visibleTabs.contains(where: { $0 === tab }), visibleTabs.contains(where: { $0 === anchor }),
              tab.spaceID == anchor.spaceID
        else { return false }
        var next = splits
        if let current = next.firstIndex(where: { $0.contains(tab.id) }) {
            if let remaining = next[current].removing(tab.id) {
                next[current] = remaining
            } else {
                next.remove(at: current)
            }
        }
        let updated: BrowserSplit
        if let at = next.firstIndex(where: { $0.contains(anchor.id) }) {
            let split = next[at]
            let position = index ?? ((split.index(of: anchor.id) ?? split.tabIDs.count - 1) + 1)
            guard let inserted = split.inserting(tab.id, at: position) else { return false }
            next[at] = inserted
            updated = inserted
        } else {
            let ids = index == 0 ? [tab.id, anchor.id] : [anchor.id, tab.id]
            guard let made = BrowserSplit(tabIDs: ids, focusedTabID: tab.id) else { return false }
            next.append(made)
            updated = made
        }
        splits = next
        keepPanesTogether(updated)
        if focus {
            selectTab(id: tab.id, focus: true)
        } else if let selected = selectedTab, updated.contains(selected.id) {
            var kept = updated
            kept.focus(selected.id)
            replaceSplit(kept)
            applyPaneLayout()
        } else {
            applyPaneLayout()
        }
        updateTabStrip()
        saveSession()
        return true
    }

    /// A split of `panes` (2–4 tabs of one Space in this window, none in a
    /// split yet), left to right with equal widths, the first focused; it
    /// shows when one of them is selected. An imported Arc split view
    /// comes in this way. False (nothing changes) when they can't pair.
    @discardableResult
    func makeSplit(of panes: [BrowserTab]) -> Bool {
        guard allowsSplits,
              panes.allSatisfy({ pane in tabs.contains { $0 === pane } && split(containing: pane.id) == nil }),
              Set(panes.map(\.spaceID)).count == 1,
              let made = BrowserSplit(tabIDs: panes.map(\.id))
        else { return false }
        splits.append(made)
        if let selected = selectedTab, made.contains(selected.id) {
            var focused = made
            focused.focus(selected.id)
            replaceSplit(focused)
            applyPaneLayout()
        }
        updateTabStrip()
        saveSession()
        return true
    }

    /// The split's Today panes become neighbors in the Space's Today order
    /// (at the first one's place, in pane order), so the row reorders and
    /// restores as one.
    private func keepPanesTogether(_ split: BrowserSplit) {
        let today = todayTabs.map(\.id)
        let panes = split.tabIDs.filter(today.contains)
        guard panes.count > 1, let first = today.firstIndex(where: panes.contains) else { return }
        var order = today.filter { !panes.contains($0) }
        let before = today[..<first].filter { !panes.contains($0) }.count
        order.insert(contentsOf: panes, at: before)
        applyTodayOrder(order)
    }

    // MARK: - Removing panes

    /// Tabs leaving the window (closed, archived, moved): out of their
    /// splits; a split left with one pane ends. Returns, for a selected
    /// pane leaving a split that keeps other panes (or a last one), the
    /// tab the selection goes to: the pane that took its place.
    @discardableResult
    func removeFromSplits(_ ids: Set<UUID>) -> UUID? {
        let selectedID = selectedTab?.id
        var successor: UUID?
        var next: [BrowserSplit] = []
        for split in splits {
            guard split.tabIDs.contains(where: ids.contains) else {
                next.append(split)
                continue
            }
            var remaining: BrowserSplit? = split
            var lastLeft: [UUID] = split.tabIDs
            for id in split.tabIDs where ids.contains(id) {
                guard let current = remaining else { break }
                lastLeft = current.tabIDs.filter { $0 != id }
                remaining = current.removing(id)
            }
            if let remaining {
                next.append(remaining)
            }
            if let selectedID, ids.contains(selectedID), split.contains(selectedID) {
                successor = remaining?.focusedTabID ?? lastLeft.first { !ids.contains($0) }
            }
        }
        splits = next
        return successor
    }

    /// ⌃⇧-: closes the focused pane's tab (as ⌘W does: a Today pane goes
    /// into the Archive, a pinned one unloads to its pin); the pane beside
    /// it takes the focus. No-op without a split on screen.
    func closeFocusedPane() {
        guard shownSplit != nil, let tab = selectedTab else { return }
        closeTab(id: tab.id, archive: true)
    }

    /// Ends the split; its tabs stay as ordinary tabs and the focused one
    /// stays selected (the others leave the screen: their idle time starts).
    func separateSplit(id: UUID) {
        guard let split = split(id: id) else { return }
        let wasShown = shownSplit?.id == id
        splits.removeAll { $0.id == id }
        if wasShown, let selected = selectedTab {
            let now = manager.tabSleeper.now()
            for tab in tabs where split.contains(tab.id) && tab !== selected {
                tab.lifecycle.lastActiveAt = now
                removeWakeSnapshot(tab)
            }
            applyPaneLayout()
        }
        updateTabStrip()
        saveSession()
    }

    /// The page of `tab` leaves the screen without another selection yet
    /// (a Space switch): every tab on it is hidden, its idle time starts
    /// and `tab` becomes the previous selection.
    func leavePage(of tab: BrowserTab) {
        previousSelectedTabID = tab.id
        let now = manager.tabSleeper.now()
        for leaving in pageTabs(of: tab) {
            leaving.lifecycle.lastActiveAt = now
            leaving.webView.isHidden = true
            removeWakeSnapshot(leaving)
        }
        splitPage.focusRing.isHidden = true
    }

    /// The split row's close button and menu: closes every pane (each as
    /// `closeTab` does: Today panes into Recently Closed, and the Archive
    /// with `archive`; pinned panes unload).
    func closeSplit(id: UUID, archive: Bool) {
        guard let split = split(id: id) else { return }
        // The focused pane last, so the selection moves once.
        let order = split.tabIDs.filter { $0 != split.focusedTabID } + [split.focusedTabID]
        for tabID in order {
            closeTab(id: tabID, archive: archive)
        }
    }

    // MARK: - Focus

    /// ⌃⇧1…⌃⇧4 and the CLI's `split focus n`: pane `number` (1-based, left
    /// to right) of the split on screen. False when there is no such pane.
    @discardableResult
    func focusPane(number: Int) -> Bool {
        guard let split = shownSplit, split.tabIDs.indices.contains(number - 1) else { return false }
        selectTab(id: split.tabIDs[number - 1], focus: true)
        return true
    }

    /// A click (or anything else) made a pane's web view first responder:
    /// that pane becomes the focused one.
    func pageBecameFirstResponder(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }), isVisiblePane(tab) else { return }
        selectTab(id: tab.id, focus: false)
    }

    // MARK: - Page layout

    /// Lays the page area out for the selected tab: the shown split's panes
    /// side by side with dividers and the focus ring on the focused pane,
    /// or the selected tab alone; every other web view is hidden. Runs on
    /// every selection and whenever a pane's web view, the split or its
    /// ratios change.
    func applyPaneLayout() {
        let page = splitPage
        NSLayoutConstraint.deactivate(page.constraints + page.focusRingConstraints)
        page.constraints = []
        page.focusRingConstraints = []
        page.dividers.forEach { $0.removeFromSuperview() }
        page.dividers = []
        page.paneViews = []
        page.shownSplitID = nil

        let shown = shownTabs
        let isSplit = shown.count > 1 && shownSplit != nil
        // A pane's sides follow the pane constraints; every other web view
        // fills the page area.
        for tab in tabs where tab.webView.superview === webArea {
            tab.webView.isHidden = !shown.contains { $0 === tab }
            let isPane = isSplit && shown.contains { $0 === tab }
            if isPane {
                NSLayoutConstraint.deactivate(tab.webView.pageEdgeConstraints)
            } else {
                NSLayoutConstraint.activate(tab.webView.pageEdgeConstraints)
            }
        }
        guard shown.count > 1, let split = shownSplit, let selected = selectedTab else {
            page.focusRing.isHidden = true
            return
        }
        page.shownSplitID = split.id
        let views = shown.map(\.webView)
        page.paneViews = views
        let gap = CGFloat(BrowserSplitLayout.gap)
        let gaps = gap * CGFloat(views.count - 1)
        let above: NSView = peek?.view ?? findBar
        var constraints: [NSLayoutConstraint] = []
        for (index, view) in views.enumerated() {
            if index == 0 {
                constraints.append(view.leadingAnchor.constraint(equalTo: webArea.leadingAnchor))
            } else {
                constraints.append(view.leadingAnchor.constraint(equalTo: views[index - 1].trailingAnchor, constant: gap))
            }
            if index == views.count - 1 {
                constraints.append(view.trailingAnchor.constraint(equalTo: webArea.trailingAnchor))
            } else {
                let ratio = CGFloat(split.ratios[index])
                constraints.append(view.widthAnchor.constraint(
                    equalTo: webArea.widthAnchor,
                    multiplier: ratio,
                    constant: -gaps * ratio
                ))
                let divider = BrowserSplitDivider(index: index, theme: theme)
                divider.onDrag = { [weak self] index, x in self?.resizeSplit(divider: index, centerX: x) }
                divider.onDragEnded = { [weak self] in self?.saveSession() }
                webArea.addSubview(divider, positioned: .below, relativeTo: above)
                constraints += [
                    divider.leadingAnchor.constraint(equalTo: view.trailingAnchor),
                    divider.trailingAnchor.constraint(equalTo: views[index + 1].leadingAnchor),
                    divider.topAnchor.constraint(equalTo: webArea.topAnchor),
                    divider.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
                ]
                page.dividers.append(divider)
            }
        }
        page.constraints = constraints
        NSLayoutConstraint.activate(constraints)

        let ring = page.focusRing
        // Above the panes, under the find bar and the Peek.
        webArea.addSubview(ring, positioned: .below, relativeTo: above)
        page.focusRingConstraints = [
            ring.topAnchor.constraint(equalTo: selected.webView.topAnchor),
            ring.bottomAnchor.constraint(equalTo: selected.webView.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: selected.webView.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: selected.webView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(page.focusRingConstraints)
        ring.isHidden = false
    }

    /// A divider dragged to `centerX` (page area coordinates): the two
    /// panes beside it resize, each at least `BrowserSplit.minimumPaneWidth`
    /// wide where the page allows.
    func resizeSplit(divider: Int, centerX: CGFloat) {
        guard let split = shownSplit else { return }
        let width = Double(webArea.bounds.width)
        let position = BrowserSplitLayout.dividerPosition(
            centerX: Double(centerX),
            divider: divider,
            width: width,
            panes: split.tabIDs.count
        )
        let resized = split.resizing(divider: divider, to: position, minimum: split.minimumShare(width: width))
        guard resized != split else { return }
        replaceSplit(resized)
        applyPaneLayout()
    }

    /// Sets the shown split's ratios outright (the harness); false without
    /// a split on screen or for ratios that don't fit it.
    @discardableResult
    func setSplitRatios(_ ratios: [Double]) -> Bool {
        guard let split = shownSplit, ratios.count == split.tabIDs.count,
              let resized = BrowserSplit(id: split.id, tabIDs: split.tabIDs, ratios: ratios, focusedTabID: split.focusedTabID)
        else { return false }
        replaceSplit(resized)
        applyPaneLayout()
        saveSession()
        return true
    }

    // MARK: - Dropping a tab onto the page

    /// Where tab `id` dragged to `x` of the page area would join the page
    /// (`BrowserSplitDrop`): a tab of this window's current Space other
    /// than the page's own, or another window's tab that may move here;
    /// nil when it can't, or when the split on screen is full.
    func splitDropTarget(id: UUID, x: CGFloat) -> Int? {
        guard allowsSplits, peek == nil, let selected = selectedTab, !(shownSplit?.isFull ?? false) else { return nil }
        if shownSplit?.contains(id) == true || id == selected.id { return nil }
        if !visibleTabs.contains(where: { $0.id == id }) {
            guard let (source, tab) = manager.tab(id: id), source !== self,
                  manager.canMoveTab(tab, from: source, to: self)
            else { return nil }
        }
        return BrowserSplitDrop.insertion(
            atX: Double(x),
            width: Double(webArea.bounds.width),
            ratios: shownSplit?.ratios ?? [1]
        )
    }

    /// Tab `id` dropped at pane index `insertion` of the page: it joins the
    /// split on screen there (another window's tab moves in first), or
    /// makes a split with the selected tab, and gets the focus.
    @discardableResult
    func dropTabOnPage(id: UUID, at insertion: Int) -> Bool {
        guard allowsSplits, let anchor = selectedTab, anchor.id != id else { return false }
        let tab: BrowserTab
        if let own = visibleTabs.first(where: { $0.id == id }) {
            tab = own
        } else {
            guard let (source, moving) = manager.tab(id: id), source !== self,
                  manager.canMoveTab(moving, from: source, to: self)
            else { return false }
            let index = tabs.filter { $0.spaceID == anchor.spaceID }.firstIndex { $0 === anchor }.map { $0 + 1 }
            manager.moveTab(moving, from: source, to: self, at: index, select: false)
            guard visibleTabs.contains(where: { $0 === moving }) else { return false }
            tab = moving
        }
        let index: Int
        if let split = shownSplit {
            index = min(max(0, insertion), split.tabIDs.count)
        } else {
            index = insertion == 0 ? 0 : 1
        }
        return addPane(tab, to: anchor, at: index, focus: true)
    }

    /// The drop marker over the pane edge a dragged tab would join
    /// (`insertion`), or hidden.
    func showSplitDropMarker(_ insertion: Int?) {
        let marker = splitPage.dropMarker
        guard let insertion else {
            marker.isHidden = true
            return
        }
        let width = Double(webArea.bounds.width)
        let frames = BrowserSplitLayout.paneFrames(width: width, ratios: shownSplit?.ratios ?? [1])
        let band = min(width / 4, BrowserSplitDrop.maximumEdge)
        let x: Double
        if insertion < frames.count {
            x = frames[insertion].x
        } else {
            x = width - band
        }
        if marker.superview !== webArea {
            webArea.addSubview(marker, positioned: .above, relativeTo: nil)
        }
        marker.frame = NSRect(x: x + 4, y: 4, width: band - 8, height: max(0, webArea.bounds.height - 8))
        marker.isHidden = false
    }

    func installSplitDrop() {
        webArea.dropTarget = { [weak self] id, x in self?.splitDropTarget(id: id, x: x) }
        webArea.onDropHover = { [weak self] insertion in self?.showSplitDropMarker(insertion) }
        webArea.onDropTab = { [weak self] id, insertion in self?.dropTabOnPage(id: id, at: insertion) ?? false }
    }

    // MARK: - Rows

    /// The current Space's tabs with whether each is a Today row.
    private var rowTabs: [(id: UUID, isToday: Bool)] {
        visibleTabs.map { (id: $0.id, isToday: !hasSpaces || $0.origin == .today) }
    }

    /// The rail's Today rows (`BrowserTabRows.today`).
    var todayRows: [BrowserTabRow] {
        BrowserTabRows.today(rowTabs, splits: splits)
    }

    /// The strip's items (`BrowserTabRows.strip`).
    var stripRows: [BrowserTabRow] {
        BrowserTabRows.strip(rowTabs, splits: splits)
    }

    /// The row the selected tab is in: its split's, else its own.
    var selectedRowID: UUID? {
        selectedTab.map { split(containing: $0.id)?.id ?? $0.id }
    }

    /// What a row renders: a tab's item, or a split's (the focused pane's
    /// title and address, every pane's favicon, loading or playing when a
    /// pane is, muted and asleep when every pane is).
    func rowItem(_ row: BrowserTabRow) -> BrowserTabItem? {
        switch row {
        case let .tab(id):
            return tabs.first { $0.id == id }.map(tabItem)
        case let .split(id):
            guard let split = split(id: id) else { return nil }
            let panes = split.tabIDs.compactMap { tabID in tabs.first { $0.id == tabID } }
            guard let focused = panes.first(where: { $0.id == split.focusedTabID }) ?? panes.first else { return nil }
            let items = panes.map(tabItem)
            let item = tabItem(focused)
            return BrowserTabItem(
                id: split.id,
                title: item.title,
                url: item.url,
                favicon: item.favicon,
                isLoading: items.contains(where: \.isLoading),
                isPlayingAudio: items.contains(where: \.isPlayingAudio),
                isMuted: items.allSatisfy(\.isMuted),
                isAsleep: items.allSatisfy(\.isAsleep),
                isLinked: false,
                isAway: false,
                panes: items.map { pane in
                    BrowserTabPaneItem(title: pane.title, favicon: pane.favicon, isFocused: pane.id == focused.id)
                }
            )
        }
    }

    /// Row `id` moved to index `index` of `rows` (the rail's Today rows or
    /// the strip's items): the current Space's Today tabs take the new
    /// order, a split's panes together.
    func moveRow(id: UUID, toIndex index: Int, in rows: [BrowserTabRow]) {
        guard let order = BrowserTabRows.todayOrder(
            moving: id,
            to: index,
            rows: rows,
            todayIDs: todayTabs.map(\.id),
            splits: splits
        ) else { return }
        applyTodayOrder(order)
    }

    /// The current Space's Today tabs (every tab in a window without
    /// Spaces) in `order`; other tabs keep their places in the window.
    func applyTodayOrder(_ order: [UUID]) {
        let today = todayTabs
        guard order != today.map(\.id), Set(order) == Set(today.map(\.id)) else { return }
        let byID = Dictionary(today.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let todayIDs = Set(order)
        var next = 0
        tabs = tabs.map { tab in
            guard todayIDs.contains(tab.id), let moved = byID[order[next]] else { return tab }
            next += 1
            return moved
        }
        updateTabStrip()
        saveSession()
    }

    /// Gap `gap` of `rows` as a gap of `visibleTabs` (before the row's
    /// first tab; past the end: the end).
    func visibleGap(forRowGap gap: Int, in rows: [BrowserTabRow]) -> Int {
        guard rows.indices.contains(gap) else { return visibleTabs.count }
        let ids: Set<UUID>
        switch rows[gap] {
        case let .tab(id): ids = [id]
        case let .split(id): ids = Set(split(id: id)?.tabIDs ?? [])
        }
        return visibleTabs.firstIndex { ids.contains($0.id) } ?? visibleTabs.count
    }

    /// A tab dropped into gap `gap` of `rows` (the rail's or the strip's):
    /// a row of this window moves there, another window's tab moves in
    /// (`dropTab`).
    @discardableResult
    func dropRow(id: UUID, atRowGap gap: Int, in rows: [BrowserTabRow]) -> Bool {
        if let from = rows.firstIndex(where: { $0.id == id }) {
            moveRow(id: id, toIndex: BrowserTabReorder.moveIndex(forInsertion: gap, from: from), in: rows)
            return true
        }
        return dropTab(id: id, at: visibleGap(forRowGap: gap, in: rows))
    }

    // MARK: - Menus

    /// A split row's menu: separate it, or close every pane.
    func splitContextMenu(for id: UUID) -> NSMenu? {
        guard split(id: id) != nil else { return nil }
        let menu = NSMenu(title: "Split View")
        menu.autoenablesItems = false
        let separate = NSMenuItem(title: "Separate Split View", action: #selector(separateSplitFromMenu(_:)), keyEquivalent: "")
        separate.target = self
        separate.representedObject = id
        menu.addItem(separate)
        let close = NSMenuItem(title: "Close Split View", action: #selector(closeSplitFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        menu.addItem(close)
        return menu
    }

    @objc func separateSplitFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        separateSplit(id: id)
    }

    @objc func closeSplitFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        closeSplit(id: id, archive: true)
    }

    /// A tab row's "Open in Split View": the tab joins the page on screen,
    /// right of the focused pane.
    @objc func openInSplitFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tabs.first(where: { $0.id == id }),
              let anchor = selectedTab
        else { return }
        addPane(tab, to: anchor, at: nil, focus: true)
    }

    // MARK: - CLI

    /// The current Space's splits in the order their first pane comes in
    /// `visibleTabs`: what the CLI's `split n` counts.
    var visibleSplits: [BrowserSplit] {
        let order = visibleTabs.map(\.id)
        return splits
            .compactMap { split in split.tabIDs.compactMap { order.firstIndex(of: $0) }.min().map { (split, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// `tabs`: `* n\t<title>\t<address>` per tab of the current Space
    /// (`*` the selected one, the focused pane in a split), and for a pane
    /// `\tsplit s, pane p of k` (`visibleSplits`, panes left to right).
    func automationTabLines() -> [String] {
        let shownSplits = visibleSplits
        return visibleTabs.enumerated().map { index, tab in
            let selected = tab.id == selectedTab?.id ? "*" : " "
            var line = "\(selected) \(index + 1)\t\(tab.displayTitle)\t\(tab.state.url ?? "about:start")"
            if let number = shownSplits.firstIndex(where: { $0.contains(tab.id) }),
               let pane = shownSplits[number].index(of: tab.id)
            {
                line += "\tsplit \(number + 1), pane \(pane + 1) of \(shownSplits[number].tabIDs.count)"
            }
            return line
        }
    }

    /// `split s, pane p of k\ttab t` for `tab`, or `tab t` outside a split.
    func automationPaneLine(_ tab: BrowserTab) -> String {
        let number = (visibleTabs.firstIndex { $0 === tab } ?? 0) + 1
        let shownSplits = visibleSplits
        guard let index = shownSplits.firstIndex(where: { $0.contains(tab.id) }),
              let pane = shownSplits[index].index(of: tab.id)
        else { return "tab \(number)" }
        return "split \(index + 1), pane \(pane + 1) of \(shownSplits[index].tabIDs.count)\ttab \(number)"
    }

    /// The CLI's `split [url]` (a new pane right of the focused one, the
    /// start page without `url`), `split close` (the focused pane, ⌃⇧-)
    /// and `split focus n` (⌃⇧n). Nothing is brought forward.
    func performSplitCommand(_ arguments: [String]) -> Result<String, Error> {
        switch arguments.first {
        case "close":
            guard shownSplit != nil, let tab = selectedTab else {
                return .failure(BrowserAutomationError.unavailable("No split view is on screen."))
            }
            let line = automationPaneLine(tab)
            closeFocusedPane()
            return .success("closed \(line)")
        case "focus":
            guard let value = arguments.dropFirst().first, let number = Int(value), number > 0 else {
                return .failure(BrowserAutomationError.invalidArguments(BrowserCommandRequest.splitUsage))
            }
            guard let split = shownSplit else {
                return .failure(BrowserAutomationError.unavailable("No split view is on screen."))
            }
            guard focusPane(number: number), let tab = selectedTab else {
                return .failure(BrowserAutomationError.invalidArguments(
                    "No pane \(number); the split has \(split.tabIDs.count)."
                ))
            }
            return .success(automationPaneLine(tab))
        case let input:
            guard allowsSplits else {
                return .failure(BrowserAutomationError.unavailable("This window has no split views."))
            }
            if let full = shownSplit, full.isFull {
                return .failure(BrowserAutomationError.unavailable(
                    "The split already has \(BrowserSplit.maximumPanes) panes."
                ))
            }
            var address: String?
            if let input {
                guard let url = BrowserAddressResolver.resolve(input, searchEngines: settingsStore.settings.searchEngines) else {
                    return .failure(BrowserAutomationError.invalidArguments("Invalid browser address: \(input)"))
                }
                address = url.absoluteString
            }
            guard let tab = addSplitPane(url: address, commandBar: false) else {
                return .failure(BrowserAutomationError.unavailable("No tab is open."))
            }
            return .success(automationPaneLine(tab))
        }
    }
}
