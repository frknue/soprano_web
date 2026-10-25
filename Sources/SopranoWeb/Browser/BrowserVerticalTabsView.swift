import AppKit

/// Arc-style vertical tab rail. Tabs stack down the left edge, with the new-tab
/// button in the header; the rail keeps the window controls clear at the top.
/// Dragging a row reorders the rail live and commits the move on release;
/// dragging it off the rail starts a system drag session that another
/// window's tab list takes, or that opens a new window where it ends. A
/// sideways two-finger swipe anywhere on the rail switches Spaces
/// (`onSwipeSpace`); swipes on the page stay the page's back/forward.
@MainActor
final class BrowserVerticalTabsView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var contextMenuProvider: ((UUID) -> NSMenu?)?
    /// Whether a tab dragged over the rail may drop here.
    var canAcceptTab: ((UUID) -> Bool)?
    /// A dragged tab dropped into gap n of the rail (0: above the first).
    var onDropTab: ((UUID, Int) -> Void)?
    /// This rail's tab was dropped where no window took it.
    var onDragOut: ((UUID, NSPoint) -> Void)? {
        get { dragSource.onDroppedOutside }
        set { dragSource.onDroppedOutside = newValue }
    }
    /// A sideways two-finger swipe on the rail: 1 for the next Space, -1
    /// for the previous one.
    var onSwipeSpace: ((Int) -> Void)?
    private var swipe = BrowserSpaceSwipe()

    private var theme: AppTheme
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var order: [UUID] = []
    private var rowWidthConstraints: [UUID: NSLayoutConstraint] = [:]
    private var selectedID: UUID?
    /// The dragged tab and the rail's live order while a row is dragged.
    private var drag: (id: UUID, order: [UUID])?
    /// "Tabs", or the window's mark: "Private", its profile, or both.
    private let headerLabel: BrowserWindowMarkView
    private let newTabButton: ChromeIconButton
    private let scrollView = BrowserRailScrollView()
    private let documentView = FlippedDocumentView()
    private let stack = BrowserVerticalTabStack()
    private let divider: ChromeRuleView
    private let dragSource = BrowserTabDragSource()
    private let dropMarker = BrowserTabDropMarker()

    static let preferredWidth: CGFloat = 232
    private static let controlsTop: CGFloat = 46
    private static let rowHeight: CGFloat = 32
    /// How far right of the rail the pointer may stray before a reorder
    /// becomes a drag out of the rail.
    private static let detachSlack: CGFloat = 16

    init(theme: AppTheme) {
        self.theme = theme
        self.headerLabel = BrowserWindowMarkView(theme: theme, fallback: "Tabs")
        self.newTabButton = ChromeIconButton(
            symbolName: "plus",
            accessibilityLabel: "New Tab",
            pointSize: 11,
            size: 22,
            target: nil,
            action: nil
        )
        self.divider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(headerLabel)

        newTabButton.target = self
        newTabButton.action = #selector(newTabPressed)
        newTabButton.toolTip = "New tab (⌘T)"
        addSubview(newTabButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.onScroll = { [weak self] event in self?.handleSwipe(event) ?? false }
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.distribution = .fill
        documentView.addSubview(stack)
        documentView.addSubview(dropMarker)

        addSubview(divider)
        registerForDraggedTypes([.browserTab])

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.controlsTop),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.leadingAnchor, constant: -8),

            newTabButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: Chrome.hairline),
        ])

        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tabs: [BrowserTabItem], selectedID: UUID) {
        let ids = tabs.map(\.id)
        if ids != order {
            if ids.count == order.count, Set(ids) == Set(buttons.keys) {
                // A reorder: keep the rows (one may be mid-drag).
                order = ids
                if drag == nil {
                    arrange(ids)
                }
            } else {
                rebuild(tabs: tabs)
            }
        }
        for tab in tabs {
            buttons[tab.id]?.item = tab
        }
        self.selectedID = selectedID
        for (id, button) in buttons {
            button.isSelected = id == selectedID
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let button = buttons[selectedID] {
            button.scrollToVisible(button.bounds)
        }
    }

    func clear() {
        for constraint in rowWidthConstraints.values {
            constraint.isActive = false
        }
        rowWidthConstraints.removeAll()
        for button in buttons.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll()
        order.removeAll()
        selectedID = nil
        drag = nil
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerLabel.apply(theme: theme)
        newTabButton.apply(theme: theme)
        divider.color = theme.colors.borderSubtle
        for button in buttons.values {
            button.apply(theme: theme)
        }
        dropMarker.apply(theme: theme)
        needsDisplay = true
    }

    /// The header shows the window's mark ("Private", its profile, or
    /// both), or "Tabs" when there is none.
    func setMark(_ mark: BrowserWindowMark) {
        headerLabel.set(mark)
    }

    /// The header's words (the harness prints them).
    var headerText: String { headerLabel.text }

    private func rebuild(tabs: [BrowserTabItem]) {
        for constraint in rowWidthConstraints.values {
            constraint.isActive = false
        }
        rowWidthConstraints.removeAll()
        for button in buttons.values {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll()
        drag = nil
        order = tabs.map(\.id)

        for tab in tabs {
            let button = BrowserTabButton(item: tab, theme: theme)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.onSelect = { [weak self] id in self?.onSelect?(id) }
            button.onClose = { [weak self] id in self?.onClose?(id) }
            button.onToggleMute = { [weak self] id in self?.onToggleMute?(id) }
            button.contextMenuProvider = { [weak self] id in self?.contextMenuProvider?(id) }
            button.onDrag = { [weak self] id, phase, event in self?.handleDrag(id, phase, event) }
            stack.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(equalTo: stack.widthAnchor)
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: Self.rowHeight),
                width,
            ])
            rowWidthConstraints[tab.id] = width
            buttons[tab.id] = button
        }
        needsLayout = true
    }

    /// Puts the rows in `ids` order without rebuilding them.
    private func arrange(_ ids: [UUID]) {
        let current = stack.arrangedSubviews.compactMap { ($0 as? BrowserTabButton)?.tabID }
        guard current != ids else { return }
        for (index, id) in ids.enumerated() {
            guard let button = buttons[id] else { continue }
            stack.removeArrangedSubview(button)
            stack.insertArrangedSubview(button, at: index)
        }
    }

    private func handleDrag(_ id: UUID, _ phase: BrowserTabButton.DragPhase, _ event: NSEvent) {
        switch phase {
        case .began:
            drag = (id, order)
        case .moved:
            guard var drag, drag.id == id else { return }
            let local = convert(event.locationInWindow, from: nil)
            if !bounds.insetBy(dx: -Self.detachSlack, dy: 0).contains(local), let button = buttons[id] {
                // Off the rail: the reorder is dropped and the tab leaves
                // in a system drag session.
                self.drag = nil
                arrange(order)
                dragSource.begin(button, event: event)
                return
            }
            let y = stack.convert(event.locationInWindow, from: nil).y
            let slot = BrowserTabReorder.slot(
                at: y,
                pitch: Self.rowHeight + stack.spacing,
                count: drag.order.count
            )
            let moved = BrowserTabReorder.moving(id, to: slot, in: drag.order)
            guard moved != drag.order else { return }
            drag.order = moved
            self.drag = drag
            arrange(moved)
            buttons[id]?.scrollToVisible(buttons[id]?.bounds ?? .zero)
        case .ended:
            guard let drag, drag.id == id else { return }
            self.drag = nil
            guard drag.order != order, let index = drag.order.firstIndex(of: id) else {
                arrange(order)
                return
            }
            order = drag.order
            onReorder?(id, index)
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
        let index = dropIndex(for: sender)
        // The move can close the source window; let the session finish first.
        DispatchQueue.main.async { [weak self] in
            self?.onDropTab?(id, index)
        }
        return true
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard let id = BrowserTabDragSource.tabID(in: sender), canAcceptTab?(id) == true else {
            dropMarker.isHidden = true
            return []
        }
        let pitch = Self.rowHeight + stack.spacing
        let gap = CGFloat(dropIndex(for: sender)) * pitch - stack.spacing / 2
        dropMarker.frame = NSRect(
            x: stack.frame.minX,
            y: stack.frame.minY + gap - 1,
            width: stack.frame.width,
            height: 2
        )
        dropMarker.isHidden = false
        return .move
    }

    private func dropIndex(for sender: any NSDraggingInfo) -> Int {
        BrowserTabReorder.railInsertionIndex(
            y: stack.convert(sender.draggingLocation, from: nil).y,
            rowPitch: Self.rowHeight + stack.spacing,
            count: order.count
        )
    }

    @objc private func newTabPressed() {
        onNewTab?()
    }

    // MARK: - Swiping between Spaces

    override func scrollWheel(with event: NSEvent) {
        if !handleSwipe(event) {
            super.scrollWheel(with: event)
        }
    }

    /// Feeds one scroll event of the rail (its header or tab list) to the
    /// swipe tracker; true when it belongs to a sideways swipe, so the
    /// list doesn't scroll with it.
    @discardableResult
    func handleSwipe(_ event: NSEvent) -> Bool {
        let direction = swipe.scroll(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            invertedFromDevice: event.isDirectionInvertedFromDevice
        )
        if let direction {
            onSwipeSpace?(direction == .next ? 1 : -1)
            return true
        }
        return swipe.isSwiping
    }
}

/// The rail's tab list: it scrolls vertically and hands every scroll event
/// to `onScroll` first, which takes sideways swipes.
private final class BrowserRailScrollView: NSScrollView {
    var onScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) != true {
            super.scrollWheel(with: event)
        }
    }
}


/// A flipped stack makes the scroll view document start at its top edge; an
/// unflipped document view pins the first tab to the bottom.
private final class BrowserVerticalTabStack: NSStackView {
    override var isFlipped: Bool { true }
}


/// The scroll document is flipped so the first row starts at the top; pinning
/// the rail stack to this plain container keeps its leading/trailing insets.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
