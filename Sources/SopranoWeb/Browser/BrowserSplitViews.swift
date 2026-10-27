import AppKit

/// The page area (`BrowserWindowController.webArea`): holds every tab's web
/// view, the find bar and the Peek, and takes a tab dragged onto a pane's
/// edge (`BrowserSplitDrop`). Web views don't read the tab pasteboard type,
/// so a tab dragged over a page reaches this view.
@MainActor
final class BrowserPageAreaView: NSView {
    /// Where a dragged tab at `x` would join the page's panes; nil when it
    /// can't drop there.
    var dropTarget: ((UUID, CGFloat) -> Int?)?
    /// Shows, or with nil hides, where a dragged tab would land.
    var onDropHover: ((Int?) -> Void)?
    /// A dragged tab dropped at pane index n (`dropTarget`'s answer).
    var onDropTab: ((UUID, Int) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.browserTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func target(for info: any NSDraggingInfo) -> (id: UUID, insertion: Int)? {
        guard let id = BrowserTabDragSource.tabID(in: info) else { return nil }
        let x = convert(info.draggingLocation, from: nil).x
        return dropTarget?(id, x).map { (id, $0) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let target = target(for: sender)
        onDropHover?(target?.insertion)
        return target == nil ? [] : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropHover?(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onDropHover?(nil) }
        guard let target = target(for: sender) else { return false }
        return onDropTab?(target.id, target.insertion) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDropHover?(nil)
    }
}

/// The gap between two panes: dragging it resizes them (`BrowserSplit
/// .resizing`). It shows a grip under the pointer and while dragged.
@MainActor
final class BrowserSplitDivider: NSView {
    let index: Int
    /// The divider's new center, in the page area's coordinates.
    var onDrag: ((Int, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private let grip = NSView()
    private var isHovered = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    init(index: Int, theme: AppTheme) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Split divider \(index + 1)")
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.wantsLayer = true
        grip.layer?.cornerRadius = 1.5
        grip.isHidden = true
        addSubview(grip)
        NSLayoutConstraint.activate([
            grip.centerXAnchor.constraint(equalTo: centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 3),
            grip.heightAnchor.constraint(equalToConstant: 36),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        grip.layer?.backgroundColor = theme.colors.textMuted.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
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
        grip.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        grip.isHidden = !isDragging
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        grip.isHidden = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(index, superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        grip.isHidden = !isHovered
        onDragEnded?()
    }
}

/// A thin ring over the focused pane of the split on screen: the pane the
/// keyboard, the toolbar and every command act on. Clicks pass through.
@MainActor
final class BrowserPaneFocusRing: NSView {
    init(theme: AppTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 4
        isHidden = true
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        layer?.borderColor = theme.colors.accent.withAlphaComponent(0.7).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Where a tab dragged onto the page lands: a band at the pane edge it
/// joins. Clicks pass through.
@MainActor
final class BrowserSplitDropMarker: NSView {
    init(theme: AppTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        layer?.backgroundColor = theme.colors.textMuted.withAlphaComponent(0.18).cgColor
        layer?.borderColor = theme.colors.textMuted.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The page area's split chrome of one window: the pane constraints, the
/// dividers, the focus ring and the drop marker
/// (`BrowserWindowController.applyPaneLayout`).
@MainActor
final class BrowserSplitPage {
    /// The split on screen; nil when the page shows one tab.
    var shownSplitID: UUID?
    /// The web views laid out as panes, left to right.
    var paneViews: [NSView] = []
    var constraints: [NSLayoutConstraint] = []
    var dividers: [BrowserSplitDivider] = []
    let focusRing: BrowserPaneFocusRing
    let dropMarker: BrowserSplitDropMarker
    var focusRingConstraints: [NSLayoutConstraint] = []

    init(theme: AppTheme) {
        focusRing = BrowserPaneFocusRing(theme: theme)
        dropMarker = BrowserSplitDropMarker(theme: theme)
    }

    func apply(theme: AppTheme) {
        focusRing.apply(theme: theme)
        dropMarker.apply(theme: theme)
        dividers.forEach { $0.apply(theme: theme) }
    }
}
