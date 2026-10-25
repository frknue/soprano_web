import AppKit

extension NSPasteboard.PasteboardType {
    /// A tab dragged out of its tab list: its id as a UUID string. Only
    /// Soprano Web's own tab lists read it.
    static let browserTab = NSPasteboard.PasteboardType("com.soprano.web.tab")
}

/// The system drag session a tab starts when the pointer leaves its tab
/// list (strip or rail) mid-drag. It shows the tab's image; another
/// window's tab list takes the drop (see the lists' `onDropTab`), and a
/// drop no window takes is reported through `onDroppedOutside`.
@MainActor
final class BrowserTabDragSource: NSObject, NSDraggingSource {
    /// The session ended where no window took the tab: the tab and the
    /// screen point. Escape cancels without reporting.
    var onDroppedOutside: ((UUID, NSPoint) -> Void)?
    private var draggedButton: BrowserTabButton?

    func begin(_ button: BrowserTabButton, event: NSEvent) {
        button.cancelPointerDrag()
        let item = NSPasteboardItem()
        item.setString(button.tabID.uuidString, forType: .browserTab)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(button.bounds, contents: button.dragImage())
        draggedButton = button
        button.alphaValue = 0.4
        let session = button.beginDraggingSession(with: [dragging], event: event, source: self)
        // A drop outside every window opens a window there; the image
        // should not fly back to the strip first.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let button = draggedButton else { return }
        draggedButton = nil
        button.alphaValue = 1
        guard operation.isEmpty, !Self.cancelledWithEscape else { return }
        let id = button.tabID
        // Moving the tab can close this window; let the session finish first.
        DispatchQueue.main.async { [weak self] in
            self?.onDroppedOutside?(id, screenPoint)
        }
    }

    private static var cancelledWithEscape: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.keyCode == 53
    }

    /// The dragged tab's id, when the drag carries one.
    static func tabID(in info: any NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: .browserTab).flatMap(UUID.init(uuidString:))
    }
}

/// The insertion line a tab list shows under a dragged tab.
@MainActor
final class BrowserTabDropMarker: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        layer?.backgroundColor = theme.colors.textMuted.cgColor
        layer?.cornerRadius = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
