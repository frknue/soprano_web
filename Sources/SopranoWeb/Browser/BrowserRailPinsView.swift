import AppKit

extension NSPasteboard.PasteboardType {
    /// A pin or folder dragged within the rail's pinned outline (its id).
    static let sopranoPinNode = NSPasteboard.PasteboardType("com.soprano.web.pin-node")
}

// MARK: - Favorites

/// One favorite in the rail's grid: its favicon and its live tab's state.
struct BrowserRailFavorite: Equatable {
    let id: UUID
    var title: String
    var url: String
    var favicon: NSImage?
    var isLive = false
    var isSelected = false
    var isAway = false

    static func == (lhs: BrowserRailFavorite, rhs: BrowserRailFavorite) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.url == rhs.url && lhs.favicon === rhs.favicon
            && lhs.isLive == rhs.isLive && lhs.isSelected == rhs.isSelected && lhs.isAway == rhs.isAway
    }
}

/// The rail's Favorites: up to 12 favicons of the profile, four to a row
/// (Arc's grid above the Space). A favorite with a live tab shows its
/// favicon at full strength with a dot under it, the selected one sits on
/// a raised tile, and one whose page moved on carries "/". Clicking opens
/// or selects it; clicking the selected one when it moved on sends it back
/// (⌘-click keeps the page in a new tab).
@MainActor
final class BrowserRailFavoritesView: NSView {
    static let columns = 4
    static let cellHeight: CGFloat = 36
    static let gap: CGFloat = 6

    /// A click on favorite `id`; `command` with ⌘.
    var onClick: ((_ id: UUID, _ command: Bool) -> Void)?
    var menuProvider: ((UUID) -> NSMenu?)?

    private(set) var items: [BrowserRailFavorite] = []
    private var cells: [BrowserRailFavoriteCell] = []
    private var theme: AppTheme
    private var height: NSLayoutConstraint!

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Every click lands here, not on a row's labels.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    func update(_ items: [BrowserRailFavorite]) {
        guard items != self.items else { return }
        self.items = items
        while cells.count < items.count {
            let cell = BrowserRailFavoriteCell(theme: theme)
            addSubview(cell)
            cells.append(cell)
        }
        while cells.count > items.count {
            cells.removeLast().removeFromSuperview()
        }
        for (cell, item) in zip(cells, items) {
            cell.item = item
        }
        let rows = (items.count + Self.columns - 1) / Self.columns
        height.constant = rows == 0 ? 0 : CGFloat(rows) * (Self.cellHeight + Self.gap) - Self.gap
        needsLayout = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        cells.forEach { $0.theme = theme }
    }

    override func layout() {
        super.layout()
        let width = (bounds.width - Self.gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
        for (index, cell) in cells.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            cell.frame = NSRect(
                x: CGFloat(column) * (width + Self.gap),
                y: CGFloat(row) * (Self.cellHeight + Self.gap),
                width: width,
                height: Self.cellHeight
            ).integral
        }
    }

    /// The favorite under a point of this view.
    private func index(at point: NSPoint) -> Int? {
        cells.firstIndex { $0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        click(items[index].id, command: event.modifierFlags.contains(.command))
    }

    /// A click on favorite `id`, as the mouse makes it (the harness too).
    func click(_ id: UUID, command: Bool) {
        onClick?(id, command)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(items[index].id)
    }
}

@MainActor
private final class BrowserRailFavoriteCell: NSView {
    var item: BrowserRailFavorite? {
        didSet {
            toolTip = item.map { $0.isAway ? "\($0.title)\n\($0.url)\nClick again to go back" : "\($0.title)\n\($0.url)" }
            setAccessibilityLabel(item?.title)
            needsDisplay = true
        }
    }
    var theme: AppTheme {
        didSet { needsDisplay = true }
    }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Drawn, not layered, so the offscreen capture shows every state.
    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let colors = theme.colors
        let tile = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        (item.isSelected ? colors.raised : (isHovered ? colors.hover : colors.bgBase)).setFill()
        tile.fill()
        (item.isSelected ? colors.borderStrong : colors.borderSubtle).setStroke()
        tile.lineWidth = Chrome.hairline
        tile.stroke()

        let size: CGFloat = 16
        let iconRect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let image = item.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        if let image {
            let tinted = item.favicon == nil ? image.tinted(colors.textMuted) : image
            tinted.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: item.isLive ? 1 : 0.5,
                respectFlipped: true,
                hints: nil
            )
        }
        if item.isLive {
            // The live mark: a small dot under the favicon.
            let dot = NSRect(x: bounds.midX - 2, y: bounds.minY + 3, width: 4, height: 4)
            colors.textMuted.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if item.isAway {
            let slash = NSAttributedString(string: "/", attributes: [
                .font: ChromeFont.labelStrong,
                .foregroundColor: colors.textMuted,
            ])
            slash.draw(at: NSPoint(x: bounds.maxX - 11, y: bounds.minY + 2))
        }
    }

    override var isFlipped: Bool { false }
}

extension NSImage {
    /// A template image drawn in `color` (a symbol in the theme's ink).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// MARK: - Pinned outline

/// The rail's pinned outline: the current Space's pins and folders
/// (`BrowserPinOutline.rows`, expanded state in `BrowserPinUIState`).
/// Clicking a pin opens or selects its live tab; clicking its icon sends
/// that tab back to the pinned address (⌘-click keeps the page in a new
/// tab); clicking a folder opens or closes it, and resting on it shows its
/// searchable preview. Rows drag to reorder and into folders: the drop is
/// `BrowserPinOutline.Drop`, which `canDrop` / `onDrop` check and apply
/// (`performBookmarkDrop`).
@MainActor
final class BrowserRailPinsView: NSView, NSDraggingSource {
    var onOpenPin: ((UUID) -> Void)?
    /// The icon of pin `id`; `command` with ⌘.
    var onPinIcon: ((_ id: UUID, _ command: Bool) -> Void)?
    var onToggleFolder: ((UUID) -> Void)?
    var menuProvider: ((UUID?) -> NSMenu?)?
    var canDrop: ((UUID, BrowserPinOutline.Drop) -> Bool)?
    var onDrop: ((UUID, BrowserPinOutline.Drop) -> Bool)?
    /// The pointer rested on folder `id` (its row's frame in this view),
    /// or left it (nil).
    var onHoverFolder: ((UUID?, NSRect) -> Void)?

    private(set) var rows: [BrowserRailPinRow] = []
    private var rowViews: [BrowserPinOutlineCellView] = []
    private var theme: AppTheme
    private var height: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var hoveredRow: Int?
    private var hoverTimer: Timer?
    private var mouseDownPoint: NSPoint?
    private var mouseDownRow: Int?
    private var isDragging = false
    private let dropMarker = BrowserTabDropMarker()
    /// An empty Space's outline: a hint, and a place to right-click for
    /// New Folder.
    private let emptyLabel = NSTextField(labelWithString: "No pinned tabs · ⌘D pins this page")
    static let emptyHeight: CGFloat = 28

    static let rowGap: CGFloat = 2
    static var pitch: CGFloat { BrowserPinOutlineCellView.rowHeight + rowGap }
    private static let dragThreshold: CGFloat = 4
    private static let hoverDelay: TimeInterval = 0.6

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        dropMarker.isHidden = true
        dropMarker.apply(theme: theme)
        addSubview(dropMarker)
        registerForDraggedTypes([.sopranoPinNode])
        emptyLabel.font = ChromeFont.meta
        emptyLabel.textColor = theme.colors.textMuted
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.frame = NSRect(x: BrowserPinOutlineCellView.iconInset, y: 6, width: 200, height: 16)
        addSubview(emptyLabel)
        height.constant = Self.emptyHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Every click lands here, not on a row's labels.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    func update(_ rows: [BrowserRailPinRow]) {
        guard rows != self.rows else { return }
        self.rows = rows
        while rowViews.count < rows.count {
            let view = BrowserPinOutlineCellView(theme: theme)
            addSubview(view, positioned: .below, relativeTo: dropMarker)
            rowViews.append(view)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        for (view, row) in zip(rowViews, rows) {
            view.configure(row, theme: theme)
        }
        if let hoveredRow, !rows.indices.contains(hoveredRow) {
            self.hoveredRow = nil
        }
        height.constant = rows.isEmpty ? Self.emptyHeight : CGFloat(rows.count) * Self.pitch - Self.rowGap
        emptyLabel.isHidden = !rows.isEmpty
        needsLayout = true
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        dropMarker.apply(theme: theme)
        emptyLabel.textColor = theme.colors.textMuted
        for view in rowViews {
            view.apply(theme: theme)
        }
    }

    override func layout() {
        super.layout()
        for (index, view) in rowViews.enumerated() {
            view.frame = NSRect(
                x: 0,
                y: CGFloat(index) * Self.pitch,
                width: bounds.width,
                height: BrowserPinOutlineCellView.rowHeight
            )
        }
    }

    /// The row view showing `id`, for the editor to hang from.
    func rowView(for id: UUID) -> NSView? {
        rows.firstIndex { $0.id == id }.map { rowViews[$0] }
    }

    private func row(at point: NSPoint) -> Int? {
        guard point.y >= 0 else { return nil }
        let index = Int(point.y / Self.pitch)
        return rows.indices.contains(index) ? index : nil
    }

    // MARK: Clicks

    /// A click on row `index` as the mouse makes it (the harness too): on
    /// a pin's icon it resets the pin's live tab, elsewhere on a pin it
    /// opens or selects it; on a folder it opens or closes the folder.
    func click(row index: Int, onIcon: Bool, command: Bool) {
        guard rows.indices.contains(index) else { return }
        let node = rows[index].row.node
        if node.isFolder {
            onToggleFolder?(node.id)
        } else if onIcon {
            onPinIcon?(node.id, command)
        } else {
            onOpenPin?(node.id)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownRow = row(at: point)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let index = mouseDownRow, !isDragging,
              rows.indices.contains(index), rowViews.indices.contains(index)
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        isDragging = true
        hideHover()
        let item = NSPasteboardItem()
        item.setString(rows[index].id.uuidString, forType: .sopranoPinNode)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let view = rowViews[index]
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(view.frame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownRow = nil
            isDragging = false
        }
        guard !isDragging, let index = mouseDownRow else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard row(at: point) == index else { return }
        let local = rowViews[index].convert(point, from: self)
        click(
            row: index,
            onIcon: rowViews[index].iconFrame.contains(local),
            command: event.modifierFlags.contains(.command)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(index.map { rows[$0].id })
    }

    // MARK: Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredRow else { return }
        if let hoveredRow, rowViews.indices.contains(hoveredRow) {
            rowViews[hoveredRow].isHovered = false
        }
        hideHover()
        hoveredRow = index
        guard let index else { return }
        rowViews[index].isHovered = true
        guard rows[index].row.node.isFolder else { return }
        let id = rows[index].id
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hoveredRow == index else { return }
                self.onHoverFolder?(id, self.rowViews[index].frame)
            }
        }
    }

    private func hideHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        onHoverFolder?(nil, .zero)
    }

    /// Shows folder `id`'s preview as resting on it does (the harness).
    func previewFolder(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        layoutSubtreeIfNeeded()
        onHoverFolder?(id, rowViews[index].frame)
    }

    // MARK: Dragging rows

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// Where a drop at `point` lands: on a folder's middle, into it; else
    /// the gap above or below the row under it; below every row, the end.
    func drop(at point: NSPoint) -> BrowserPinOutline.Drop {
        guard point.y >= 0 else { return .above(0) }
        let index = Int(point.y / Self.pitch)
        guard rows.indices.contains(index) else { return .above(rows.count) }
        let fraction = (point.y - CGFloat(index) * Self.pitch) / BrowserPinOutlineCellView.rowHeight
        if rows[index].row.node.isFolder, fraction > 0.25, fraction < 0.75 {
            return .on(index)
        }
        return .above(fraction < 0.5 ? index : index + 1)
    }

    private func draggedID(_ info: NSDraggingInfo) -> UUID? {
        guard (info.draggingSource as? BrowserRailPinsView) === self,
              let text = info.draggingPasteboard.string(forType: .sopranoPinNode)
        else { return nil }
        return UUID(uuidString: text)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropMarks()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearDropMarks()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        clearDropMarks()
        guard let id = draggedID(sender) else { return false }
        return onDrop?(id, drop(at: convert(sender.draggingLocation, from: nil))) ?? false
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        clearDropMarks()
        guard let id = draggedID(sender) else { return [] }
        let drop = drop(at: convert(sender.draggingLocation, from: nil))
        guard canDrop?(id, drop) == true else { return [] }
        switch drop {
        case let .on(index):
            rowViews[index].isDropTarget = true
        case let .above(index):
            dropMarker.frame = NSRect(x: 0, y: CGFloat(index) * Self.pitch - Self.rowGap / 2 - 1, width: bounds.width, height: 2)
            dropMarker.isHidden = false
        }
        return .move
    }

    private func clearDropMarks() {
        dropMarker.isHidden = true
        for view in rowViews where view.isDropTarget {
            view.isDropTarget = false
        }
    }
}
