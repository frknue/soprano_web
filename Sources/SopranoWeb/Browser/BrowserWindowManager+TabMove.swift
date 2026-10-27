import AppKit

/// Moving live tabs between windows: Move Tab to New Window, dragging a tab
/// onto another window or out of every window, Merge All Windows,
/// `move-to-window`, and pop-up windows. A moved tab keeps its web view, so
/// its page, back/forward list, audio, zoom and find query come along and
/// nothing reloads.
extension BrowserWindowManager {
    /// Whether `tab` may move from `source` into `target`'s tab list: never
    /// into a pop-up window, and only when `target`'s current Space uses
    /// the tab's data context (`BrowserTabMoveRule`). Drops,
    /// `move-to-window` and the menu all ask here.
    func canMoveTab(_ tab: BrowserTab, from source: BrowserWindowController, to target: BrowserWindowController) -> Bool {
        BrowserTabMoveRule.allows(tabContext: tab.dataContext.id, from: source.id, to: target.moveRuleWindow)
    }

    /// Moves `tab` into `target`'s current Space at `index` of that Space
    /// (nil: the end). It stays linked to its pin or favorite while that
    /// is the target Space's and `target` has no live tab for it yet
    /// (`BrowserPinLinks.originAfterMove`); otherwise it lands as a Today
    /// tab. `select` selects it there and brings `target` forward;
    /// otherwise neither window's selection changes except where the tab
    /// left. An emptied `source` closes without going onto Recently
    /// Closed.
    func moveTab(
        _ tab: BrowserTab,
        from source: BrowserWindowController,
        to target: BrowserWindowController,
        at index: Int?,
        select: Bool
    ) {
        guard canMoveTab(tab, from: source, to: target), source.tabs.contains(where: { $0 === tab }) else { return }
        let find = source.findQuery(carriedBy: tab)
        source.detachTab(tab)
        tab.spaceID = target.currentSpaceID
        tab.origin = linkAfterMove(tab, into: target)
        target.attachTab(tab, at: index, select: select)
        if select {
            target.carryFind(find)
            present(target)
        }
        closeIfEmptied(source)
        scheduleSessionSave()
    }

    /// Window ▸ Move Tab to New Window, a tab dropped where no window took
    /// it, Vimium `W` and `move-to-window new`: `tab` becomes the only tab
    /// of a new window of its data context (a private tab stays private),
    /// on the tab's Space (a pop-up's tab: its profile's first Space), at
    /// `frame` (session coordinates; nil: cascaded from `source`). `raise`
    /// brings the window forward; otherwise it is ordered in behind
    /// `source` and does not become the default window.
    @discardableResult
    func moveTabToNewWindow(
        _ tab: BrowserTab,
        from source: BrowserWindowController,
        frame: NSRect? = nil,
        raise: Bool = true
    ) -> BrowserWindowController? {
        guard source.tabs.contains(where: { $0 === tab }) else { return nil }
        let controller = makeWindow(
            frame: frame ?? frameForNewWindow(cascadingFrom: source),
            context: tab.dataContext,
            spaceID: tab.spaceID ?? source.littleSpaceID,
            activate: raise
        )
        let find = source.findQuery(carriedBy: tab)
        source.detachTab(tab)
        tab.spaceID = controller.currentSpaceID
        tab.origin = linkAfterMove(tab, into: controller)
        controller.attachTab(tab, select: true)
        controller.carryFind(find)
        if raise {
            present(controller)
        } else {
            orderInBehind(controller, source: source)
        }
        closeIfEmptied(source)
        scheduleSessionSave()
        return controller
    }

    /// A tab dragged out of `source` and dropped at `screenPoint` (the
    /// window's real screen coordinates) where no window took it: a new
    /// window of `source`'s size with the pointer over its first tab.
    @discardableResult
    func moveTabToNewWindow(
        _ tab: BrowserTab,
        from source: BrowserWindowController,
        droppedAt screenPoint: NSPoint
    ) -> BrowserWindowController? {
        let point = NSPoint(x: screenPoint.x - placement.offset.x, y: screenPoint.y - placement.offset.y)
        let size = source.role.isCompact
            ? (tabbedController.flatMap(sessionFrame(of:))?.size ?? placement.defaultFrame().size)
            : (sessionFrame(of: source)?.size ?? placement.defaultFrame().size)
        let frame = BrowserWindowFrames.dropped(
            at: point,
            size: size,
            screens: placement.screens(),
            minSize: Self.windowMinSize
        )
        return moveTabToNewWindow(tab, from: source, frame: frame)
    }

    /// The windows Merge All Windows empties into `target`
    /// (`BrowserTabMoveRule.merges`): every other normal window, or the
    /// other private windows of a private target's context.
    func mergeSources(into target: BrowserWindowController) -> [BrowserWindowController] {
        controllers.filter { BrowserTabMoveRule.merges($0.moveRuleWindow, into: target.moveRuleWindow) }
    }

    /// Window ▸ Merge All Windows: every tab of the other windows that
    /// merge into the active window moves into it, after its tabs and in
    /// window order, each keeping its Space and its pin or favorite link
    /// unless the active window already has a live tab for it; its
    /// selected tab stays selected. The emptied windows close without going
    /// onto Recently Closed. Pop-up windows, and windows of another kind or
    /// private context, stay as they are.
    func mergeAllWindows() {
        guard let target = tabbedController else { return }
        let sources = mergeSources(into: target)
        guard !sources.isEmpty else { return }
        let selected = target.selectedTab?.id
        for source in sources {
            let tabs = source.tabs
            let leaving = BrowserWindowMerge.detachOrder(tabs: tabs.map(\.id), selected: source.selectedTab?.id)
            for id in leaving {
                if let tab = tabs.first(where: { $0.id == id }) {
                    source.detachTab(tab)
                }
            }
            for tab in tabs {
                tab.origin = linkAfterMove(tab, into: target)
                target.attachTab(tab, select: false)
            }
            closeIfEmptied(source)
        }
        if let selected {
            target.selectTab(id: selected, focus: true)
        }
        present(target)
        scheduleSessionSave()
    }

    /// A page's `window.open` with a size: `tab` (made from WebKit's
    /// configuration, so `window.opener` works and it shares the opener's
    /// data store) in a compact window of the opener's data context, sized
    /// and placed from `features`.
    @discardableResult
    func openPopupWindow(
        with tab: BrowserTab,
        features: BrowserPopupFeatures,
        opener: BrowserWindowController
    ) -> BrowserWindowController {
        let frame = BrowserPopupWindowFrame.frame(
            for: features,
            chromeHeight: BrowserToolbarView.preferredHeight,
            opener: sessionFrame(of: opener),
            screens: placement.screens()
        )
        let controller = makeWindow(frame: frame, role: .popup, context: tab.dataContext)
        controller.attachTab(tab, select: true)
        present(controller)
        return controller
    }

    /// Whether a pop-up window `tab` opened is still open (its `opener`
    /// would break if the tab slept).
    func hasPopupWindow(openedBy tab: BrowserTab) -> Bool {
        controllers.contains { $0.role == .popup && $0.tabs.contains { $0.links.openerID == tab.id } }
    }

    private func closeIfEmptied(_ controller: BrowserWindowController) {
        if controller.tabs.isEmpty {
            closeWindow(controller)
        }
    }

    /// Shows a window without making it key or front: right behind
    /// `source` (in the harness, behind everything and off every display).
    private func orderInBehind(_ controller: BrowserWindowController, source: BrowserWindowController) {
        guard let window = controller.window else { return }
        if placement.isOffscreen {
            window.orderBack(nil)
        } else if let sourceWindow = source.window, sourceWindow.isVisible {
            window.order(.below, relativeTo: sourceWindow.windowNumber)
        } else {
            window.orderBack(nil)
        }
        window.displayIfNeeded()
    }
}

extension BrowserWindowManager {
    /// The link `tab` keeps when it joins `target` in Space `tab.spaceID`
    /// (set before): its pin or favorite must be that Space's and `target`
    /// must have no live tab for it yet.
    func linkAfterMove(_ tab: BrowserTab, into target: BrowserWindowController) -> BrowserTabOrigin {
        guard target.hasSpaces, let spaceID = tab.spaceID else { return .today }
        return BrowserPinLinks.originAfterMove(
            tab.origin,
            into: spaces.linkTargets(inSpace: spaceID),
            live: target.tabs.filter { $0 !== tab }.map(\.origin)
        )
    }
}
