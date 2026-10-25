import CoreGraphics

/// Index math for dragging a tab along the strip or the rail.
enum BrowserTabReorder {
    /// The slot under `offset` along a run of `count` slots, each `pitch`
    /// long and starting at 0. Positions before the first slot or past the
    /// last clamp to the ends.
    static func slot(at offset: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard pitch > 0, offset.isFinite else { return 0 }
        let index = Int((offset / pitch).rounded(.down))
        return min(max(0, index), count - 1)
    }

    /// `order` with `element` moved so it ends up at `index` (clamped),
    /// the same result as `BrowserWindowController.moveTab(id:toIndex:)`.
    static func moving<Element: Equatable>(_ element: Element, to index: Int, in order: [Element]) -> [Element] {
        guard let from = order.firstIndex(of: element) else { return order }
        let target = min(max(0, index), order.count - 1)
        guard target != from else { return order }
        var result = order
        result.insert(result.remove(at: from), at: target)
        return result
    }
}
