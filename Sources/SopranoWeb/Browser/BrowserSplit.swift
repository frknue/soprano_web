import Foundation

/// A split view (Arc's): 2–4 tabs of one Space shown side by side in one
/// window, as one rail row and one strip item. The panes stay ordinary tabs
/// of the window's `tabs` and `visibleTabs` with their own origin (pinned,
/// favorite or Today); the window keeps its splits
/// (`BrowserWindowController.splits`). `tabIDs` are the panes left to
/// right; `ratios` their shares of the page width without the dividers,
/// summing to 1; `focusedTabID` the pane focused last, which selecting the
/// split's row selects. While a pane is the selected tab, the split is on
/// screen and that pane is the focused one.
struct BrowserSplit: Equatable, Sendable {
    static let maximumPanes = 4
    /// The narrowest a divider drag leaves a pane, in points.
    static let minimumPaneWidth: Double = 240

    let id: UUID
    private(set) var tabIDs: [UUID]
    private(set) var ratios: [Double]
    private(set) var focusedTabID: UUID

    /// Nil unless `tabIDs` holds at least 2 distinct tabs; tabs past the
    /// fourth are left out. Ratios that don't fit (count, a share that is
    /// not positive) give equal panes; others are scaled to sum to 1. A
    /// focus that is not a pane falls to the first pane.
    init?(id: UUID = UUID(), tabIDs: [UUID], ratios: [Double]? = nil, focusedTabID: UUID? = nil) {
        var seen = Set<UUID>()
        let unique = tabIDs.filter { seen.insert($0).inserted }
        guard unique.count >= 2 else { return nil }
        let panes = Array(unique.prefix(Self.maximumPanes))
        self.id = id
        self.tabIDs = panes
        self.ratios = Self.normalized(unique.count == tabIDs.count ? ratios.map { Array($0.prefix(panes.count)) } : nil, count: panes.count)
        self.focusedTabID = focusedTabID.flatMap { panes.contains($0) ? $0 : nil } ?? panes[0]
    }

    var isFull: Bool { tabIDs.count >= Self.maximumPanes }

    func contains(_ tabID: UUID) -> Bool {
        tabIDs.contains(tabID)
    }

    /// The pane's 0-based place, left to right.
    func index(of tabID: UUID) -> Int? {
        tabIDs.firstIndex(of: tabID)
    }

    /// `ratios` scaled to sum to 1; equal shares when they don't fit
    /// `count`.
    static func normalized(_ ratios: [Double]?, count: Int) -> [Double] {
        let equal = Array(repeating: 1 / Double(max(count, 1)), count: count)
        guard let ratios, ratios.count == count, ratios.allSatisfy({ $0.isFinite && $0 > 0 }) else { return equal }
        let sum = ratios.reduce(0, +)
        return ratios.map { $0 / sum }
    }

    // MARK: Changes

    /// The pane `tabID` becomes the focused one (no-op for another tab).
    mutating func focus(_ tabID: UUID) {
        guard contains(tabID) else { return }
        focusedTabID = tabID
    }

    /// A new pane at `index` (clamped), focused, taking an equal share:
    /// 1/(n+1) of the width, the others shrinking in proportion. Nil when
    /// the split is full or already has the tab.
    func inserting(_ tabID: UUID, at index: Int) -> BrowserSplit? {
        guard !isFull, !contains(tabID) else { return nil }
        let count = Double(tabIDs.count)
        var next = self
        let at = min(max(0, index), tabIDs.count)
        next.tabIDs.insert(tabID, at: at)
        next.ratios = ratios.map { $0 * count / (count + 1) }
        next.ratios.insert(1 / (count + 1), at: at)
        next.focusedTabID = tabID
        return next
    }

    /// Without pane `tabID`, the others growing in proportion. The focus
    /// moves to the pane that takes its place (else the new last pane).
    /// Nil when one pane would be left: the split ends and its last tab
    /// is an ordinary tab again. The same split for another tab.
    func removing(_ tabID: UUID) -> BrowserSplit? {
        guard let index = index(of: tabID) else { return self }
        guard tabIDs.count > 2 else { return nil }
        var next = self
        next.tabIDs.remove(at: index)
        next.ratios.remove(at: index)
        next.ratios = Self.normalized(next.ratios, count: next.tabIDs.count)
        if focusedTabID == tabID {
            next.focusedTabID = next.tabIDs[min(index, next.tabIDs.count - 1)]
        }
        return next
    }

    /// Divider `divider` (between panes `divider` and `divider + 1`) moved
    /// to `position`, a fraction of the panes' total width from the left.
    /// Only the two panes beside it change; each keeps at least `minimum`
    /// (a fraction). Unchanged for an unknown divider or when the two
    /// panes are already narrower than that together.
    func resizing(divider: Int, to position: Double, minimum: Double) -> BrowserSplit {
        guard divider >= 0, divider + 1 < tabIDs.count, position.isFinite else { return self }
        let start = ratios[..<divider].reduce(0, +)
        let end = start + ratios[divider] + ratios[divider + 1]
        let low = start + minimum
        let high = end - minimum
        guard low <= high else { return self }
        let clamped = min(max(position, low), high)
        var next = self
        next.ratios[divider] = clamped - start
        next.ratios[divider + 1] = end - clamped
        return next
    }

    /// The least share a divider drag leaves a pane in a page `width`
    /// points wide (`minimumPaneWidth`, at most an equal share).
    func minimumShare(width: Double) -> Double {
        let content = BrowserSplitLayout.contentWidth(width: width, panes: tabIDs.count)
        guard content > 0 else { return 1 / Double(tabIDs.count) }
        return min(Self.minimumPaneWidth / content, 1 / Double(tabIDs.count))
    }

    // MARK: Session

    /// What the session saves, with tabs as indices of `windowTabs` (the
    /// window's tabs in order); nil when a pane is not among them.
    func state(windowTabs: [UUID]) -> BrowserSplitState? {
        let indices = tabIDs.compactMap { windowTabs.firstIndex(of: $0) }
        guard indices.count == tabIDs.count else { return nil }
        return BrowserSplitState(tabs: indices, ratios: ratios, focused: index(of: focusedTabID) ?? 0)
    }

    /// The splits of a saved window whose tabs restored as `tabIDs` (in
    /// the saved order) in `spaceIDs`: a split with a pane index out of
    /// range, panes of different Spaces or a tab already in an earlier
    /// split is dropped; fewer than 2 panes is no split.
    static func restored(_ states: [BrowserSplitState], tabIDs: [UUID], spaceIDs: [UUID?]) -> [BrowserSplit] {
        var used = Set<Int>()
        var result: [BrowserSplit] = []
        for state in states {
            guard state.tabs.allSatisfy({ tabIDs.indices.contains($0) && spaceIDs.indices.contains($0) }),
                  Set(state.tabs.map { spaceIDs[$0] }).count == 1,
                  used.isDisjoint(with: state.tabs)
            else { continue }
            let focused = state.tabs.indices.contains(state.focused) ? tabIDs[state.tabs[state.focused]] : nil
            guard let split = BrowserSplit(
                tabIDs: state.tabs.map { tabIDs[$0] },
                ratios: state.ratios,
                focusedTabID: focused
            ) else { continue }
            used.formUnion(state.tabs)
            result.append(split)
        }
        return result
    }
}

/// A split in `session.json`: its panes as indices of the window's `tabs`,
/// their ratios and the focused pane (an index of `tabs` here). Added in
/// session version 5.
struct BrowserSplitState: Codable, Equatable, Sendable {
    var tabs: [Int]
    var ratios: [Double]
    var focused = 0

    private enum CodingKeys: String, CodingKey {
        case tabs, ratios, focused
    }

    init(tabs: [Int], ratios: [Double], focused: Int = 0) {
        self.tabs = tabs
        self.ratios = ratios
        self.focused = focused
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decode([Int].self, forKey: .tabs)
        ratios = (try? c.decodeIfPresent([Double].self, forKey: .ratios)) ?? []
        focused = (try? c.decodeIfPresent(Int.self, forKey: .focused)) ?? 0
    }
}

// MARK: - Page layout

/// Where a split's panes and dividers sit across a page area `width`
/// points wide: panes left to right with a `gap` between neighbors
/// (the divider a drag resizes), sharing the rest by `ratios`.
enum BrowserSplitLayout {
    /// The divider between two panes.
    static let gap: Double = 6

    /// The panes' total width: the page without the dividers.
    static func contentWidth(width: Double, panes: Int, gap: Double = gap) -> Double {
        max(0, width - gap * Double(max(panes - 1, 0)))
    }

    /// Each pane's left edge and width, in whole points; the last pane
    /// takes what rounding leaves.
    static func paneFrames(width: Double, ratios: [Double], gap: Double = gap) -> [(x: Double, width: Double)] {
        guard !ratios.isEmpty else { return [] }
        let content = contentWidth(width: width, panes: ratios.count, gap: gap)
        var frames: [(x: Double, width: Double)] = []
        var x = 0.0
        for (index, ratio) in ratios.enumerated() {
            let paneWidth = index == ratios.count - 1 ? max(0, width - x) : (content * ratio).rounded()
            frames.append((x, paneWidth))
            x += paneWidth + gap
        }
        return frames
    }

    /// The position (`BrowserSplit.resizing`'s fraction of the panes'
    /// width) of divider `divider` whose center is at `centerX`.
    static func dividerPosition(centerX: Double, divider: Int, width: Double, panes: Int, gap: Double = gap) -> Double {
        let content = contentWidth(width: width, panes: panes, gap: gap)
        guard content > 0 else { return 0 }
        return (centerX - gap / 2 - gap * Double(divider)) / content
    }
}

/// A tab dragged onto the page: dropped near a pane's left or right edge it
/// joins the split there (the page's lone tab and it become a split).
enum BrowserSplitDrop {
    /// The share of a pane's width at each side that takes a drop.
    static let edgeShare = 0.25
    /// The widest an edge zone gets, in points.
    static let maximumEdge = 160.0

    /// The pane index (0…panes) a tab dropped at `x` of a page `width`
    /// points wide joins at, for the panes `ratios` (`[1]` for a page
    /// without a split); nil in the middle of a pane or on a divider.
    static func insertion(atX x: Double, width: Double, ratios: [Double], gap: Double = BrowserSplitLayout.gap) -> Int? {
        let frames = BrowserSplitLayout.paneFrames(width: width, ratios: ratios, gap: gap)
        for (index, frame) in frames.enumerated() where x >= frame.x && x <= frame.x + frame.width {
            let edge = min(frame.width * edgeShare, maximumEdge)
            if x < frame.x + edge { return index }
            if x > frame.x + frame.width - edge { return index + 1 }
            return nil
        }
        return nil
    }
}

// MARK: - Rows

/// One row of the rail's Today list or one strip item: a tab, or a split
/// (all its panes).
enum BrowserTabRow: Equatable, Sendable {
    case tab(UUID)
    case split(UUID)

    /// The tab's or the split's id: what the row's view is keyed by.
    var id: UUID {
        switch self {
        case let .tab(id), let .split(id): id
        }
    }
}

/// How a window's tabs become rows once splits exist (1 row ≠ 1 tab).
enum BrowserTabRows {
    /// The rail's Today rows for the current Space's `tabs` (in
    /// `visibleTabs` order, `isToday` from their origin): every Today tab,
    /// a split at its first Today pane's place, and first the splits with
    /// no Today pane (only pinned or favorite panes).
    static func today(_ tabs: [(id: UUID, isToday: Bool)], splits: [BrowserSplit]) -> [BrowserTabRow] {
        let present = Set(tabs.map(\.id))
        let today = Set(tabs.filter(\.isToday).map(\.id))
        let shown = splits.filter { split in split.tabIDs.allSatisfy(present.contains) }
        var rows: [BrowserTabRow] = shown
            .filter { split in !split.tabIDs.contains(where: today.contains) }
            .map { .split($0.id) }
        var placed = Set<UUID>()
        for tab in tabs where tab.isToday {
            if let split = shown.first(where: { $0.contains(tab.id) }) {
                if placed.insert(split.id).inserted {
                    rows.append(.split(split.id))
                }
            } else {
                rows.append(.tab(tab.id))
            }
        }
        return rows
    }

    /// The strip's items: the pinned and favorite tabs outside a split
    /// (compact, first), then the Today rows.
    static func strip(_ tabs: [(id: UUID, isToday: Bool)], splits: [BrowserSplit]) -> [BrowserTabRow] {
        let present = Set(tabs.map(\.id))
        let inSplit = Set(splits.filter { $0.tabIDs.allSatisfy(present.contains) }.flatMap(\.tabIDs))
        let linked = tabs.filter { !$0.isToday && !inSplit.contains($0.id) }.map { BrowserTabRow.tab($0.id) }
        return linked + today(tabs, splits: splits)
    }

    /// The Today tabs' order after row `id` moves to index `index` of
    /// `rows` (clamped): the rows' Today tabs in row order, a split's in
    /// pane order. `todayIDs` are the Today tabs as they are; nil when
    /// `id` is not a row.
    static func todayOrder(
        moving id: UUID,
        to index: Int,
        rows: [BrowserTabRow],
        todayIDs: [UUID],
        splits: [BrowserSplit]
    ) -> [UUID]? {
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return nil }
        var order = rows
        let row = order.remove(at: from)
        order.insert(row, at: min(max(0, index), order.count))
        let today = Set(todayIDs)
        var result: [UUID] = []
        for row in order {
            switch row {
            case let .tab(tabID):
                if today.contains(tabID) { result.append(tabID) }
            case let .split(splitID):
                result += splits.first { $0.id == splitID }?.tabIDs.filter(today.contains) ?? []
            }
        }
        // Today tabs no row lists (none expected) keep their order at the end.
        let listed = Set(result)
        return result + todayIDs.filter { !listed.contains($0) }
    }
}
