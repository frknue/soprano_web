import CoreGraphics

/// Index math for dragging a tab along the strip or the rail, and for
/// dropping a tab from another window (or back from a system drag) onto it.
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

    /// The gap under `offset` along a run of `count` slots, each `pitch`
    /// long and starting at 0: 0 before the first slot, `count` after the
    /// last. A slot's first half drops before it, its second half after it.
    static func insertionIndex(at offset: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0, offset.isFinite else { return 0 }
        let index = Int((offset / pitch).rounded())
        return min(max(0, index), count)
    }

    /// Where a tab dropped at `x` (strip coordinates) goes in the
    /// horizontal strip: its visible run starts at `leading` and shows
    /// `visibleCount` tabs, `tabWidth` apart, from tab `visibleStart` on.
    static func stripInsertionIndex(
        x: CGFloat,
        leading: CGFloat,
        tabWidth: CGFloat,
        visibleStart: Int,
        visibleCount: Int
    ) -> Int {
        visibleStart + insertionIndex(at: x - leading, pitch: tabWidth, count: visibleCount)
    }

    /// Where a tab dropped at `y` (from the top of the first row) goes in
    /// the vertical rail of `count` rows, `rowPitch` apart.
    static func railInsertionIndex(y: CGFloat, rowPitch: CGFloat, count: Int) -> Int {
        insertionIndex(at: y, pitch: rowPitch, count: count)
    }

    /// The `moveTab(id:toIndex:)` index for the tab at `from` dropped into
    /// gap `insertion` of its own list (it leaves its slot first).
    static func moveIndex(forInsertion insertion: Int, from: Int) -> Int {
        insertion > from ? insertion - 1 : insertion
    }
}
