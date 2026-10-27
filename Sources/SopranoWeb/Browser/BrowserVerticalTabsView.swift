import AppKit

/// What the rail shows above and below the Today tabs.
struct BrowserRailContent: Equatable {
    /// A normal window: Favorites, Pinned, the "Today" head and the Space
    /// switcher. A private or pop-up window shows its tabs only.
    var showsSpaces = false
    var favorites: [BrowserRailFavorite] = []
    var pins: [BrowserRailPinRow] = []
    var spaces: [BrowserRailSpace] = []
}

/// Arc-style vertical tab rail, top to bottom: the Space header (its icon,
/// name and color mark; a private window's mark), the profile's Favorites
/// grid, the Space's pinned outline, the "Today" head with "+ New Tab" and
/// the Today tabs, and the Space switcher; the rail keeps the window
/// controls clear at the top. Dragging a Today row reorders the rail live
/// and commits the move on release; dragging it off the rail starts a
/// system drag session that another window's tab list takes, or that
/// opens a new window where it ends. A sideways two-finger swipe anywhere
/// on the rail switches Spaces (`onSwipeSpace`); swipes on the page stay
/// the page's back/forward.
@MainActor
final class BrowserVerticalTabsView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNewTab: (() -> Void)? {
        get { todayHeader.onNewTab }
        set { todayHeader.onNewTab = newValue }
    }
    /// A Today row dragged to index n of the Today tabs.
    var onReorder: ((UUID, Int) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var contextMenuProvider: ((UUID) -> NSMenu?)?
    /// Whether a tab dragged over the rail may drop here.
    var canAcceptTab: ((UUID) -> Bool)?
    /// A dragged tab dropped into gap n of the Today tabs (0: above the
    /// first).
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

    /// The Favorites grid, the pinned outline and the Space switcher; the
    /// window controller wires their callbacks.
    let favoritesView: BrowserRailFavoritesView
    let pinsView: BrowserRailPinsView
    let switcher: BrowserRailSpaceSwitcher
    let todayHeader: BrowserRailTodayHeader
    private(set) var content = BrowserRailContent()

    private var theme: AppTheme
    private var buttons: [UUID: BrowserTabButton] = [:]
    private var order: [UUID] = []
    private(set) var todayItems: [BrowserTabItem] = []
    private var rowWidthConstraints: [UUID: NSLayoutConstraint] = [:]
    private(set) var selectedID: UUID?
    /// The dragged tab and the rail's live order while a row is dragged.
    private var drag: (id: UUID, order: [UUID])?
    /// The current Space (icon, name, color mark), or the window's mark:
    /// "Private", its profile, or both.
    private let headerLabel: BrowserWindowMarkView
    private let scrollView = BrowserRailScrollView()
    private let documentView = FlippedDocumentView()
    private let sections = BrowserVerticalTabStack()
    private let stack = BrowserVerticalTabStack()
    private let divider: ChromeRuleView
    private let dragSource = BrowserTabDragSource()
    private let dropMarker = BrowserTabDropMarker()
    private var scrollToSwitcher: NSLayoutConstraint!
    private var scrollToBottom: NSLayoutConstraint!

    static let preferredWidth: CGFloat = 232
    private static let controlsTop: CGFloat = 46
    private static let rowHeight: CGFloat = 32
    /// How far right of the rail the pointer may stray before a reorder
    /// becomes a drag out of the rail.
    private static let detachSlack: CGFloat = 16

    init(theme: AppTheme) {
        self.theme = theme
        self.headerLabel = BrowserWindowMarkView(theme: theme, fallback: "Tabs")
        self.divider = ChromeRuleView(axis: .vertical, color: theme.colors.borderSubtle)
        self.favoritesView = BrowserRailFavoritesView(theme: theme)
        self.pinsView = BrowserRailPinsView(theme: theme)
        self.switcher = BrowserRailSpaceSwitcher(theme: theme)
        self.todayHeader = BrowserRailTodayHeader(theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(headerLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.onScroll = { [weak self] event in self?.handleSwipe(event) ?? false }
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        sections.translatesAutoresizingMaskIntoConstraints = false
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 10
        sections.distribution = .fill
        sections.detachesHiddenViews = true
        documentView.addSubview(sections)
        documentView.addSubview(dropMarker)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.distribution = .fill
        for view in [favoritesView, pinsView, todayHeader, stack] as [NSView] {
            sections.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        sections.setCustomSpacing(4, after: todayHeader)

        addSubview(switcher)
        addSubview(divider)
        registerForDraggedTypes([.browserTab])

        scrollToSwitcher = scrollView.bottomAnchor.constraint(equalTo: switcher.topAnchor)
        scrollToBottom = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.controlsTop),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollToBottom,

            switcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            switcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            switcher.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            sections.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            sections.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            sections.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            sections.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: Chrome.hairline),
        ])

        update(content: content)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The sections around the Today tabs.
    func update(content: BrowserRailContent) {
        let modeChanged = content.showsSpaces != self.content.showsSpaces
        self.content = content
        favoritesView.update(content.favorites)
        pinsView.update(content.pins)
        switcher.update(content.spaces)
        favoritesView.isHidden = !content.showsSpaces || content.favorites.isEmpty
        pinsView.isHidden = !content.showsSpaces || content.pins.isEmpty
        switcher.isHidden = !content.showsSpaces
        if modeChanged || scrollToSwitcher.isActive != content.showsSpaces {
            todayHeader.setShowsLabel(content.showsSpaces)
            scrollToBottom.isActive = false
            scrollToSwitcher.isActive = false
            (content.showsSpaces ? scrollToSwitcher : scrollToBottom).isActive = true
        }
        needsLayout = true
    }

    /// The Today tabs (every tab in a window without Spaces) and the
    /// selected tab, which may be a pinned or favorite one.
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
        todayItems = tabs
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
        } else if let row = pinsView.rowView(for: selectedPinID ?? UUID()) {
            row.scrollToVisible(row.bounds)
        }
    }

    /// The pin whose live tab is selected.
    private var selectedPinID: UUID? {
        content.pins.first { $0.isSelected }?.id
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
        todayItems.removeAll()
        selectedID = nil
        drag = nil
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        headerLabel.apply(theme: theme)
        divider.color = theme.colors.borderSubtle
        for button in buttons.values {
            button.apply(theme: theme)
        }
        favoritesView.apply(theme: theme)
        pinsView.apply(theme: theme)
        switcher.apply(theme: theme)
        todayHeader.apply(theme: theme)
        dropMarker.apply(theme: theme)
        needsDisplay = true
    }

    /// The header shows the current Space (icon, name, color mark), or a
    /// window without Spaces' mark ("Private", its profile, or both), or
    /// "Tabs" when there is none.
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
        let list = documentView.convert(stack.bounds, from: stack)
        dropMarker.frame = NSRect(x: list.minX, y: list.minY + gap - 1, width: list.width, height: 2)
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
