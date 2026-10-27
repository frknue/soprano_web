import AppKit

/// The pure parts of switching a normal window's Space: ⌃1…⌃9 (the Nth
/// Space), ⌥⌘←/⌥⌘→ (previous/next, wrapping around) and which tab a Space
/// selects when the window shows it.
enum BrowserSpaceSwitch {
    /// Space `number` (1-based, display order); nil past the end.
    static func space(number: Int, in spaces: [UUID]) -> UUID? {
        spaces.indices.contains(number - 1) ? spaces[number - 1] : nil
    }

    /// The Space `step` places after `current` (negative: before),
    /// wrapping around the ends; the first Space when `current` is not
    /// listed. Nil without Spaces.
    static func neighbor(of current: UUID?, step: Int, in spaces: [UUID]) -> UUID? {
        guard !spaces.isEmpty else { return nil }
        guard let current, let index = spaces.firstIndex(of: current) else { return spaces.first }
        let count = spaces.count
        return spaces[((index + step) % count + count) % count]
    }

    /// The tab a Space selects when the window switches to it: its
    /// remembered tab while that is still in the Space, else the one used
    /// most recently. Nil for an empty Space (the window opens a start tab).
    static func selection(remembered: UUID?, tabs: [(id: UUID, lastActive: Date)]) -> UUID? {
        if let remembered, tabs.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return tabs.max { $0.lastActive < $1.lastActive }?.id
    }
}

/// The rail's two-finger horizontal swipe: fingers moving left show the
/// next Space, right the previous one, once per gesture. Feed it every
/// scroll event of the rail; vertical scrolling, momentum and wheel mice
/// (no phase) never switch.
struct BrowserSpaceSwipe: Equatable {
    enum Direction: Equatable {
        case previous
        case next
    }

    /// How far (points) the fingers travel sideways before the Space
    /// changes.
    static let threshold: CGFloat = 60

    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var fired = false

    /// One scroll event. `invertedFromDevice` is
    /// `NSEvent.isDirectionInvertedFromDevice` (natural scrolling), so the
    /// fingers' direction is the same either way. Returns the switch the
    /// gesture asks for, at most once per gesture.
    mutating func scroll(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        invertedFromDevice: Bool
    ) -> Direction? {
        guard momentumPhase.isEmpty, !phase.isEmpty else { return nil }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            horizontal = 0
            vertical = 0
            fired = false
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            horizontal = 0
            vertical = 0
            fired = false
            return nil
        }
        guard !fired else { return nil }
        horizontal += invertedFromDevice ? deltaX : -deltaX
        vertical += abs(deltaY)
        guard abs(horizontal) >= Self.threshold, abs(horizontal) > 2 * vertical else { return nil }
        fired = true
        return horizontal > 0 ? .previous : .next
    }

    /// Whether the gesture in progress is a sideways swipe (the rail keeps
    /// it from scrolling the tab list).
    var isSwiping: Bool {
        fired || (horizontal != 0 && abs(horizontal) > 2 * vertical)
    }
}
