import AppKit
import WebKit

/// Which windows may exchange live tabs. A tab's web view keeps its data
/// store for life, so a tab only moves between windows of one data context:
/// every normal window shares one, a private window shares its own only with
/// the windows its tabs moved into. A pop-up window holds only the tab its
/// page opened.
enum BrowserTabMoveRule {
    struct Window: Equatable, Sendable {
        var id: UUID
        /// The window's `BrowserDataContext.id`.
        var context: UUID
        var isPopup: Bool
    }

    static func allows(from source: Window, to target: Window) -> Bool {
        source.id != target.id && !target.isPopup && source.context == target.context
    }
}

/// Window ▸ Merge All Windows: the order tabs leave and arrive in.
enum BrowserWindowMerge {
    /// The order to take a window's tabs out in: the selected tab last, so
    /// the window never selects (and so loads) another tab on the way out.
    static func detachOrder<ID: Equatable>(tabs: [ID], selected: ID?) -> [ID] {
        guard let selected, tabs.contains(selected) else { return tabs }
        return tabs.filter { $0 != selected } + [selected]
    }

    /// The target window's tabs, then every other window's tabs in window
    /// order, each keeping its own order. The target's selected tab stays
    /// selected at the same index.
    static func merged<ID: Equatable>(
        target: [ID],
        selectedIndex: Int,
        others: [[ID]]
    ) -> (tabs: [ID], selectedIndex: Int) {
        (target + others.flatMap { $0 }, selectedIndex)
    }
}

/// The parts of `WKWindowFeatures` a pop-up window uses, in CSS pixels
/// (one point at zoom 1). `left`/`top` are measured from the top-left
/// corner of the main screen's visible area.
struct BrowserPopupFeatures: Equatable, Sendable {
    var width: Double?
    var height: Double?
    var left: Double?
    var top: Double?

    init(width: Double? = nil, height: Double? = nil, left: Double? = nil, top: Double? = nil) {
        self.width = width
        self.height = height
        self.left = left
        self.top = top
    }

    @MainActor
    init(_ features: WKWindowFeatures) {
        self.init(
            width: features.width?.doubleValue,
            height: features.height?.doubleValue,
            left: features.x?.doubleValue,
            top: features.y?.doubleValue
        )
    }

    /// `window.open` asked for a size: the page gets its own small window.
    /// Without one it opens as a tab after the opener.
    var opensWindow: Bool {
        width != nil || height != nil
    }
}

/// Frames for pop-up windows (`window.open` with a size).
enum BrowserPopupWindowFrame {
    /// The smallest page area a pop-up gets, whatever the page asks for.
    static let minimumContentSize = NSSize(width: 360, height: 200)
    /// The page area when neither the page nor an opener window gives one.
    static let defaultContentSize = NSSize(width: 800, height: 600)

    /// The window frame for `features`: a page area of the requested size
    /// (a missing side from the opener's page area) below `chromeHeight` of
    /// compact toolbar, at `left`/`top` when given and otherwise centered on
    /// the opener window, then kept on a screen. `screens[0]` is the main
    /// screen's visible frame; frames use AppKit's bottom-left origin.
    static func frame(
        for features: BrowserPopupFeatures,
        chromeHeight: CGFloat,
        opener: NSRect?,
        screens: [NSRect]
    ) -> NSRect {
        let fallback = opener.map { NSSize(width: $0.width, height: max(0, $0.height - chromeHeight)) }
            ?? defaultContentSize
        let content = NSSize(
            width: max(minimumContentSize.width, features.width.map { CGFloat($0) } ?? fallback.width),
            height: max(minimumContentSize.height, features.height.map { CGFloat($0) } ?? fallback.height)
        )
        let size = NSSize(width: content.width, height: content.height + chromeHeight)
        let main = screens.first ?? NSRect(origin: .zero, size: size)
        let center = opener.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: main.midX, y: main.midY)
        let x = features.left.map { main.minX + CGFloat($0) } ?? center.x - size.width / 2
        let y = features.top.map { main.maxY - CGFloat($0) - size.height } ?? center.y - size.height / 2
        return BrowserWindowFrames.clamped(
            NSRect(origin: NSPoint(x: x, y: y), size: size),
            to: screens,
            minSize: minimumWindowSize(chromeHeight: chromeHeight)
        )
    }

    static func minimumWindowSize(chromeHeight: CGFloat) -> NSSize {
        NSSize(width: minimumContentSize.width, height: minimumContentSize.height + chromeHeight)
    }
}
