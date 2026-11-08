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
/// next Space, right the previous one, once per gesture. A two-finger
/// gesture is never perfectly straight, so it locks onto the axis it leads
/// with in its first points: a vertical scroll of the tab list stays the
/// list's even when the hand drifts sideways, and a sideways swipe still
/// counts when it drifts up or down. A sideways flick that falls short of
/// the threshold switches while its momentum runs; momentum after a
/// vertical scroll and wheel mice (no phases) never switch.
struct BrowserSpaceSwipe: Equatable {
    enum Direction: Equatable {
        case previous
        case next
    }

    /// How far (points) the fingers travel sideways before the Space
    /// changes.
    static let threshold: CGFloat = 60
    /// How far a gesture travels before its axis is known, and how much
    /// one axis has to lead the other there.
    private static let axisTravel: CGFloat = 10
    private static let axisRatio: CGFloat = 1.5

    private enum Axis: Equatable {
        case undecided
        case horizontal
        case vertical
    }

    private var axis = Axis.undecided
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var fired = false
    /// The fingers lifted on a sideways gesture that fell short: what the
    /// flick's momentum adds may still switch.
    private var tracksMomentum = false
    private var systemSwipeFired = false

    /// One scroll event of the rail. `invertedFromDevice` is
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
        guard !phase.isEmpty || !momentumPhase.isEmpty else { return nil }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            self = Self()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            if !fired, axis == .horizontal {
                // Short of the threshold with the fingers still going: the
                // flick's momentum can carry it over.
                tracksMomentum = true
                axis = .undecided
            } else {
                self = Self()
            }
            return nil
        }
        if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
            self = Self()
            return nil
        }
        let sideways = invertedFromDevice ? deltaX : -deltaX
        if momentumPhase.isEmpty {
            guard !phase.isEmpty, !fired else { return nil }
            if axis == .undecided {
                horizontal += sideways
                vertical += abs(deltaY)
                if max(abs(horizontal), vertical) >= Self.axisTravel {
                    if abs(horizontal) >= Self.axisRatio * vertical {
                        axis = .horizontal
                    } else if vertical >= Self.axisRatio * abs(horizontal) {
                        axis = .vertical
                    }
                }
            } else if axis == .horizontal {
                horizontal += sideways
            }
        } else {
            guard tracksMomentum, !fired else { return nil }
            horizontal += sideways
        }
        let sidewaysGesture = momentumPhase.isEmpty ? axis == .horizontal : tracksMomentum
        guard sidewaysGesture, abs(horizontal) >= Self.threshold else { return nil }
        fired = true
        return horizontal > 0 ? .previous : .next
    }

    /// A system swipe event (`NSResponder.swipe(with:)`): the trackpad's
    /// own gesture, `deltaX` 1 for fingers left and -1 for right, the same
    /// with or without natural scrolling. A gesture that reports phases
    /// switches once, however many events it sends; a device that sends one
    /// phase-less event per gesture switches per event.
    mutating func swipe(deltaX: CGFloat, phase: NSEvent.Phase) -> Direction? {
        if phase.contains(.ended) || phase.contains(.cancelled) {
            systemSwipeFired = false
            return nil
        }
        if phase.contains(.began) || phase.contains(.mayBegin) || phase.isEmpty {
            systemSwipeFired = false
        }
        guard deltaX != 0, !systemSwipeFired else { return nil }
        systemSwipeFired = true
        return deltaX > 0 ? .next : .previous
    }

    /// Whether the gesture in progress is a sideways swipe (the rail keeps
    /// it from scrolling the tab list).
    var isSwiping: Bool {
        axis == .horizontal
    }
}
