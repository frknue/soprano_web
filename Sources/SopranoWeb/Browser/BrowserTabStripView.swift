import AppKit

/// The row of tabs above the toolbar. Tabs share the available width down to
/// a readable minimum; when they no longer fit, the strip keeps the selected
/// tab visible and puts the rest behind an overflow menu. Dragging a tab
/// reorders the strip live and commits the move on release; dragging it
/// off the strip starts a system drag session that another window's tab
/// list takes, or that opens a new window where it ends.
@MainActor
final class BrowserTabStripView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var contextMenuProvider: ((UUID) -> NSMenu?)?
    /// Whether a tab dragged over the strip may drop here.
    var canAcceptTab: ((UUID) -> Bool)?
    /// A dragged tab dropped into gap n of the strip (0: before the first).
    var onDropTab: ((UUID, Int) -> Void)?
    /// This strip's tab was dropped where no window took it.
    var onDragOut: ((UUID, NSPoint) -> Void)? {
        get { dragSource.onDroppedOutside }
        set { dragSource.onDroppedOutside = newValue }
    }

    private struct Drag {
        let id: UUID
        var order: [UUID]
        let grabOffset: CGFloat
        var pointerX: CGFloat
    }

    private var theme: AppTheme
    private var order: [UUID] = []
    private var titles: [UUID: String] = [:]
    private var selectedID: UUID?
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var visibleIDs: [UUID] = []
    private var overflowIDs: [UUID] = []
    private var drag: Drag?
    private var tabWidth: CGFloat = 0
    private var visibleStart = 0
    private var visibleCount = 0
    /// Pinned and favorite tabs: first, icon-only, never in the overflow.
    private var linkedIDs: Set<UUID> = []
    private var compactCount = 0
    /// The compact tabs that fit (the rest are in the overflow menu).
    private var shownCompactCount = 0
    private let dragSource = BrowserTabDragSource()
    private let dropMarker = BrowserTabDropMarker()

    private let newTabButton: ChromeIconButton
    private let overflowButton: ChromeIconButton

    static let trafficLightInset: CGFloat = 76
    static let preferredHeight: CGFloat = 40
    private static let minimumTabWidth: CGFloat = 58
    private static let readableTabWidth: CGFloat = 96
    private static let maximumTabWidth: CGFloat = 220
    private static let controlsWidth: CGFloat = 58
    private static let tabHeight: CGFloat = 30
    private static let compactTabWidth: CGFloat = 38
    /// How far above or below the strip the pointer may stray before a
    /// reorder becomes a drag out of the strip.
    private static let detachSlack: CGFloat = 16

    init(theme: AppTheme) {
        self.theme = theme
        self.newTabButton = ChromeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Tab",
            pointSize: 11,
            size: 22,
            target: nil,
            action: nil
        )
        self.overflowButton = ChromeIconButton(
            symbolName: "chevron.down",
            accessibilityLabel: "All Tabs",
            pointSize: 10,
            size: 22,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(newTabButton)
        addSubview(overflowButton)
        newTabButton.target = self
        newTabButton.action = #selector(newTabPressed)
        overflowButton.target = self
        overflowButton.action = #selector(overflowPressed)
        overflowButton.isHidden = true
        newTabButton.toolTip = "New tab (⌘T)"
        overflowButton.toolTip = "All tabs"
        addSubview(dropMarker)
        dropMarker.apply(theme: theme)
        registerForDraggedTypes([.browserTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tabs: [BrowserTabItem], selectedID: UUID) {
        let ids = tabs.map(\.id)
        if ids != order {
            if ids.count == order.count, Set(ids) == Set(buttons.keys) {
                // A reorder: keep the buttons (one may be mid-drag).
                order = ids
            } else {
                rebuild(tabs: tabs)
            }
        }
        linkedIDs = Set(tabs.filter(\.isLinked).map(\.id))
        for tab in tabs {
            buttons[tab.id]?.item = tab
            buttons[tab.id]?.isCompact = tab.isLinked
        }
        if var drag, Set(drag.order) != Set(order) {
            drag.order = order
            self.drag = drag
        }
        self.titles = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        self.selectedID = selectedID
        for (id, button) in buttons {
            button.isSelected = id == selectedID
        }
        needsLayout = true
    }

    func clear() {
        for button in buttons.values {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order.removeAll()
        titles.removeAll()
        selectedID = nil
        drag = nil
        visibleIDs = []
        overflowIDs = []
        overflowButton.isHidden = true
        needsLayout = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        newTabButton.apply(theme: theme)
        overflowButton.apply(theme: theme)
        for button in buttons.values {
            button.apply(theme: theme)
        }
        dropMarker.apply(theme: theme)
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
    }

    /// Where the Today run starts, after the compact pinned tabs shown.
    private var regularLeading: CGFloat {
        Self.trafficLightInset + CGFloat(shownCompactCount) * Self.compactTabWidth
    }

    private func layoutTabs(animated: Bool) {
        let fullOrder = drag?.order ?? order
        compactCount = fullOrder.prefix { linkedIDs.contains($0) }.count
        let displayOrder = Array(fullOrder.dropFirst(compactCount))

        // Compact tabs take what is left after the controls (and one
        // readable Today tab); the rest go to the overflow menu, the
        // selected one always staying in the strip.
        let compactAll = Array(fullOrder.prefix(compactCount))
        let compactRoom = bounds.width - Self.trafficLightInset - Self.controlsWidth
            - (displayOrder.isEmpty ? 0 : Self.minimumTabWidth)
        let fitting = compactAll.count * Int(Self.compactTabWidth) <= Int(compactRoom)
            ? compactAll.count
            : max(0, Int((compactRoom - 24) / Self.compactTabWidth))
        var shownCompact = Array(compactAll.prefix(fitting))
        if let selectedID, compactAll.contains(selectedID), !shownCompact.contains(selectedID), !shownCompact.isEmpty {
            shownCompact[shownCompact.count - 1] = selectedID
        }
        let hiddenCompact = compactAll.filter { !shownCompact.contains($0) }
        shownCompactCount = shownCompact.count

        let left = regularLeading
        let right = Self.controlsWidth
        let available = max(0, bounds.width - left - right)

        let newTabSize: CGFloat = 22
        let overflowSize: CGFloat = 22
        let y = floor((bounds.height - Self.tabHeight) / 2)
        for id in hiddenCompact {
            buttons[id]?.isHidden = true
        }
        for (index, id) in shownCompact.enumerated() {
            guard let button = buttons[id] else { continue }
            button.isHidden = false
            button.frame = NSRect(
                x: Self.trafficLightInset + CGFloat(index) * Self.compactTabWidth,
                y: y,
                width: Self.compactTabWidth - 2,
                height: Self.tabHeight
            )
        }

        guard !displayOrder.isEmpty else {
            newTabButton.frame = NSRect(
                x: left + 6,
                y: floor((bounds.height - newTabSize) / 2),
                width: newTabSize,
                height: newTabSize
            )
            visibleIDs = shownCompact
            overflowIDs = hiddenCompact
            overflowButton.isHidden = overflowIDs.isEmpty
            overflowButton.frame = overflowIDs.isEmpty ? .zero : NSRect(
                x: left + 6 + newTabSize + 2,
                y: floor((bounds.height - overflowSize) / 2),
                width: overflowSize,
                height: overflowSize
            )
            visibleStart = 0
            visibleCount = 0
            return
        }

        var width = min(Self.maximumTabWidth, available / CGFloat(displayOrder.count))
        if width < Self.readableTabWidth {
            width = max(Self.minimumTabWidth, available / CGFloat(displayOrder.count))
        }

        var visibleCount = displayOrder.count
        if width <= Self.minimumTabWidth, CGFloat(displayOrder.count) * Self.minimumTabWidth > available {
            visibleCount = max(1, Int(available / Self.minimumTabWidth))
            width = max(0, available / CGFloat(visibleCount))
        }

        let selectedIndex = selectedID.flatMap { displayOrder.firstIndex(of: $0) } ?? 0
        let start: Int
        if visibleCount >= displayOrder.count {
            start = 0
        } else {
            start = min(max(0, selectedIndex - visibleCount + 1), displayOrder.count - visibleCount)
        }
        tabWidth = width
        visibleStart = start
        self.visibleCount = visibleCount
        let visibleRange = start..<(start + visibleCount)
        visibleIDs = shownCompact + Array(displayOrder[visibleRange])
        overflowIDs = hiddenCompact + Array(displayOrder[..<start]) + Array(displayOrder[(start + visibleCount)...])
        overflowButton.isHidden = overflowIDs.isEmpty

        let controlsStart = left + width * CGFloat(visibleCount) + 6
        newTabButton.frame = NSRect(
            x: controlsStart,
            y: floor((bounds.height - newTabSize) / 2),
            width: newTabSize,
            height: newTabSize
        )
        overflowButton.frame = NSRect(
            x: controlsStart + newTabSize + 2,
            y: floor((bounds.height - overflowSize) / 2),
            width: overflowSize,
            height: overflowSize
        )

        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, id) in displayOrder.enumerated() {
            guard let button = buttons[id] else { continue }
            guard visibleRange.contains(index) else {
                button.isHidden = true
                continue
            }
            button.isHidden = false
            var frame = NSRect(
                x: left + CGFloat(index - start) * width,
                y: y,
                width: max(0, width - 2),
                height: Self.tabHeight
            )
            if let drag, drag.id == id {
                // The dragged tab follows the pointer inside the visible run.
                let minX = left
                let maxX = left + CGFloat(visibleCount - 1) * width
                frame.origin.x = min(max(minX, drag.pointerX - drag.grabOffset), maxX)
                button.frame = frame
            } else if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    button.animator().frame = frame
                }
            } else {
                button.frame = frame
            }
        }
    }

    private func rebuild(tabs: [BrowserTabItem]) {
        for button in buttons.values {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        drag = nil
        order = tabs.map(\.id)

        for tab in tabs {
            let button = BrowserTabButton(item: tab, theme: theme)
            button.isCompact = tab.isLinked
            button.onSelect = { [weak self] id in self?.onSelect?(id) }
            button.onClose = { [weak self] id in self?.onClose?(id) }
            button.onToggleMute = { [weak self] id in self?.onToggleMute?(id) }
            button.contextMenuProvider = { [weak self] id in self?.contextMenuProvider?(id) }
            button.onDrag = { [weak self] id, phase, event in self?.handleDrag(id, phase, event) }
            addSubview(button)
            buttons[tab.id] = button
        }
        needsLayout = true
    }

    private func handleDrag(_ id: UUID, _ phase: BrowserTabButton.DragPhase, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x
        switch phase {
        case .began:
            // Pinned and favorite tabs keep their place.
            guard let button = buttons[id], !linkedIDs.contains(id) else { return }
            addSubview(button, positioned: .above, relativeTo: nil)
            drag = Drag(id: id, order: order, grabOffset: x - button.frame.minX, pointerX: x)
        case .moved:
            guard var drag, drag.id == id, visibleCount > 0 else { return }
            if !bounds.insetBy(dx: 0, dy: -Self.detachSlack).contains(point), let button = buttons[id] {
                // Off the strip: the reorder is dropped and the tab leaves
                // in a system drag session.
                self.drag = nil
                layoutTabs(animated: true)
                dragSource.begin(button, event: event)
                return
            }
            drag.pointerX = x
            let slot = BrowserTabReorder.slot(
                at: x - regularLeading,
                pitch: tabWidth,
                count: visibleCount
            )
            drag.order = BrowserTabReorder.moving(id, to: compactCount + visibleStart + slot, in: drag.order)
            self.drag = drag
            layoutTabs(animated: true)
        case .ended:
            guard let drag, drag.id == id else { return }
            self.drag = nil
            let changed = drag.order != order
            if changed {
                order = drag.order
            }
            layoutTabs(animated: true)
            if changed, let index = drag.order.firstIndex(of: id) {
                onReorder?(id, index)
            }
        }
    }

    // MARK: - Dropping a dragged tab

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropMarker.isHidden = true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropMarker.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropMarker.isHidden = true
        guard let id = BrowserTabDragSource.tabID(in: sender), canAcceptTab?(id) == true else { return false }
        let index = compactCount + dropIndex(for: sender)
        // The move can close the source window; let the session finish first.
        DispatchQueue.main.async { [weak self] in
            self?.onDropTab?(id, index)
        }
        return true
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard let id = BrowserTabDragSource.tabID(in: sender), canAcceptTab?(id) == true, visibleCount > 0 else {
            dropMarker.isHidden = true
            return []
        }
        let index = dropIndex(for: sender)
        dropMarker.frame = NSRect(
            x: regularLeading + CGFloat(index - visibleStart) * tabWidth - 2,
            y: floor((bounds.height - Self.tabHeight) / 2),
            width: 2,
            height: Self.tabHeight
        )
        addSubview(dropMarker, positioned: .above, relativeTo: nil)
        dropMarker.isHidden = false
        return .move
    }

    private func dropIndex(for sender: any NSDraggingInfo) -> Int {
        BrowserTabReorder.stripInsertionIndex(
            x: convert(sender.draggingLocation, from: nil).x,
            leading: regularLeading,
            tabWidth: tabWidth,
            visibleStart: visibleStart,
            visibleCount: visibleCount
        )
    }

    @objc private func newTabPressed() {
        onNewTab?()
    }

    @objc private func overflowPressed() {
        let menu = NSMenu(title: "All Tabs")
        for id in order {
            let item = NSMenuItem(
                title: titles[id] ?? "Untitled",
                action: #selector(selectFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            item.state = id == selectedID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeSelected), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: overflowButton.frame.minX, y: bounds.minY),
            in: self
        )
    }

    @objc private func selectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(id)
    }

    @objc private func closeSelected() {
        guard let selectedID else { return }
        onClose?(selectedID)
    }
}
