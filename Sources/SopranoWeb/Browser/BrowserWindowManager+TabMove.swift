import AppKit

/// Moving live tabs between windows: Move Tab to New Window, dragging a tab
/// onto another window or out of every window, Merge All Windows,
/// `move-to-window`, and pop-up windows. A moved tab keeps its web view, so
/// its page, back/forward list, audio, zoom and find query come along and
/// nothing reloads.
extension BrowserWindowManager {
    /// Whether a tab may move from `source` into `target`'s tab list: never
    /// into a pop-up window, and only between windows of one data context
    /// (normal with normal, a private window with the windows its tabs
    /// moved into). Drops, Merge All Windows, `move-to-window` and the menu
    /// all ask here.
    func canMoveTab(from source: BrowserWindowController, to target: BrowserWindowController) -> Bool {
        BrowserTabMoveRule.allows(from: source.moveRuleWindow, to: target.moveRuleWindow)
    }

    /// Moves `tab` into `target` at `index` (nil: the end). `select` selects
    /// it there and brings `target` forward; otherwise neither window's
    /// selection changes except where the tab left. An emptied `source`
    /// closes without going onto Recently Closed.
    func moveTab(
        _ tab: BrowserTab,
        from source: BrowserWindowController,
        to target: BrowserWindowController,
        at index: Int?,
        select: Bool
    ) {
        guard canMoveTab(from: source, to: target), source.tabs.contains(where: { $0 === tab }) else { return }
        let find = source.findQuery(carriedBy: tab)
        source.detachTab(tab)
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
    /// of a new window of `source`'s data context (a private tab stays
    /// private) at `frame` (session coordinates; nil: cascaded from
    /// `source`). `raise` brings the window forward; otherwise it is ordered
    /// in behind `source` and does not become the default window.
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
            context: source.dataContext,
            activate: raise
        )
        let find = source.findQuery(carriedBy: tab)
        source.detachTab(tab)
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
        let size = source.isPopup
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

    /// The windows Merge All Windows empties into `target`: the other
    /// windows of its data context.
    func mergeSources(into target: BrowserWindowController) -> [BrowserWindowController] {
        guard !target.isPopup else { return [] }
        return controllers.filter { !$0.isPopup && canMoveTab(from: $0, to: target) }
    }

    /// Window ▸ Merge All Windows: every tab of the other windows of the
    /// active window's data context moves into it, after its tabs and in
    /// window order; its selected tab stays selected. The emptied windows
    /// close without going onto Recently Closed. Pop-up windows, and normal
    /// or private windows of another context, stay as they are.
    func mergeAllWindows() {
        guard let target = tabbedController else { return }
        let sources = mergeSources(into: target)
        guard !sources.isEmpty else { return }
        let plan = BrowserWindowMerge.merged(
            target: target.tabs.map(\.id),
            selectedIndex: target.selectedIndex,
            others: sources.map { $0.tabs.map(\.id) }
        )
        for source in sources {
            let tabs = source.tabs
            let leaving = BrowserWindowMerge.detachOrder(tabs: tabs.map(\.id), selected: source.selectedTab?.id)
            for id in leaving {
                if let tab = tabs.first(where: { $0.id == id }) {
                    source.detachTab(tab)
                }
            }
            for tab in tabs {
                target.attachTab(tab, at: plan.tabs.firstIndex(of: tab.id), select: false)
            }
            closeIfEmptied(source)
        }
        target.selectTab(index: plan.selectedIndex, focus: true)
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
        let controller = makeWindow(frame: frame, isPopup: true, context: opener.dataContext)
        controller.attachTab(tab, select: true)
        present(controller)
        return controller
    }

    /// Whether a pop-up window `tab` opened is still open (its `opener`
    /// would break if the tab slept).
    func hasPopupWindow(openedBy tab: BrowserTab) -> Bool {
        controllers.contains { $0.isPopup && $0.tabs.contains { $0.links.openerID == tab.id } }
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
