@testable import SopranoWeb
import AppKit
import Testing

/// ⌃1…⌃9, ⌥⌘←/⌥⌘→, which tab a Space selects, and the rail's swipe.
struct BrowserSpaceSwitchTests {
    private let spaces = [UUID(), UUID(), UUID()]

    @Test func numbersCountSpacesInDisplayOrder() {
        #expect(BrowserSpaceSwitch.space(number: 1, in: spaces) == spaces[0])
        #expect(BrowserSpaceSwitch.space(number: 3, in: spaces) == spaces[2])
        #expect(BrowserSpaceSwitch.space(number: 4, in: spaces) == nil)
        #expect(BrowserSpaceSwitch.space(number: 0, in: spaces) == nil)
    }

    @Test func nextAndPreviousWrapAround() {
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[0], step: 1, in: spaces) == spaces[1])
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[2], step: 1, in: spaces) == spaces[0])
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[0], step: -1, in: spaces) == spaces[2])
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[1], step: -1, in: spaces) == spaces[0])
        // One Space: it is its own neighbor; none: nothing.
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[0], step: 1, in: [spaces[0]]) == spaces[0])
        #expect(BrowserSpaceSwitch.neighbor(of: spaces[0], step: 1, in: []) == nil)
        // A Space that is gone: the first.
        #expect(BrowserSpaceSwitch.neighbor(of: UUID(), step: -1, in: spaces) == spaces[0])
    }

    @Test func aSpaceSelectsItsRememberedElseItsMostRecentTab() {
        let old = (id: UUID(), lastActive: Date(timeIntervalSince1970: 100))
        let recent = (id: UUID(), lastActive: Date(timeIntervalSince1970: 200))
        #expect(BrowserSpaceSwitch.selection(remembered: old.id, tabs: [old, recent]) == old.id)
        // The remembered tab left the Space.
        #expect(BrowserSpaceSwitch.selection(remembered: UUID(), tabs: [old, recent]) == recent.id)
        #expect(BrowserSpaceSwitch.selection(remembered: nil, tabs: [recent, old]) == recent.id)
        // An empty Space selects nothing (the window opens a start tab).
        #expect(BrowserSpaceSwitch.selection(remembered: old.id, tabs: []) == nil)
    }

    @Test func swipingRightShowsTheNextSpaceOncePerGesture() {
        var swipe = BrowserSpaceSwipe()
        // Without natural scrolling, fingers moving right scroll left.
        #expect(swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: -30, deltaY: 2, invertedFromDevice: false) == nil)
        #expect(swipe.isSwiping)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: -40, deltaY: 1, invertedFromDevice: false) == .next)
        // The rest of the gesture switches nothing more.
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: -90, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.isSwiping)
        #expect(swipe.scroll(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(!swipe.isSwiping)
        // With natural scrolling the deltas follow the fingers: left is
        // the previous Space.
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: true)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: -70, deltaY: 0, invertedFromDevice: true) == .previous)
    }

    @Test func verticalScrollsMomentumAndWheelsNeverSwitch() {
        var swipe = BrowserSpaceSwipe()
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        // Mostly vertical: the tab list scrolls.
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 70, deltaY: 50, invertedFromDevice: false) == nil)
        #expect(!swipe.isSwiping)
        _ = swipe.scroll(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        // Momentum after a lift, and a wheel mouse (no phase).
        #expect(swipe.scroll(phase: [], momentumPhase: .changed, deltaX: 200, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: [], momentumPhase: [], deltaX: 200, deltaY: 0, invertedFromDevice: false) == nil)
    }

    @Test func aSidewaysSwipeCountsWhenTheHandDriftsVertically() {
        var swipe = BrowserSpaceSwipe()
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        // A real hand moves down as it swipes; the sideways lead decides.
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 25, deltaY: 12, invertedFromDevice: false) == nil)
        #expect(swipe.isSwiping)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 25, deltaY: 12, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 25, deltaY: 12, invertedFromDevice: false) == .previous)
    }

    @Test func aVerticalScrollWithSidewaysDriftNeverSwitches() {
        var swipe = BrowserSpaceSwipe()
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        // Scrolling the tab list: the sideways drift stays the list's too.
        for _ in 0..<4 {
            #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 8, deltaY: 30, invertedFromDevice: false) == nil)
            #expect(!swipe.isSwiping)
        }
        _ = swipe.scroll(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        // Its momentum doesn't switch either.
        #expect(swipe.scroll(phase: [], momentumPhase: .changed, deltaX: 120, deltaY: 0, invertedFromDevice: false) == nil)
    }

    @Test func aShortSidewaysFlickSwitchesOnItsMomentum() {
        var swipe = BrowserSpaceSwipe()
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 40, deltaY: 3, invertedFromDevice: false) == nil)
        _ = swipe.scroll(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false)
        #expect(!swipe.isSwiping)
        // The flick's momentum carries the rest, then switches nothing more.
        #expect(swipe.scroll(phase: [], momentumPhase: .began, deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: [], momentumPhase: .changed, deltaX: 30, deltaY: 0, invertedFromDevice: false) == .previous)
        #expect(swipe.scroll(phase: [], momentumPhase: .changed, deltaX: 90, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: [], momentumPhase: .ended, deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
    }

    @Test func aSystemSwipeEventSwitchesOncePerGesture() {
        var swipe = BrowserSpaceSwipe()
        // Fingers left is deltaX 1, right -1, whatever the scrolling setting.
        #expect(swipe.swipe(deltaX: 1, phase: .began) == .previous)
        #expect(swipe.swipe(deltaX: 1, phase: .changed) == nil)
        #expect(swipe.swipe(deltaX: 1, phase: .changed) == nil)
        #expect(swipe.swipe(deltaX: 0, phase: .ended) == nil)
        // The next swipe starts fresh.
        #expect(swipe.swipe(deltaX: -1, phase: .began) == .next)
        // A device that sends one event per swipe without a phase switches
        // on each of them.
        #expect(swipe.swipe(deltaX: 1, phase: []) == .previous)
        #expect(swipe.swipe(deltaX: -1, phase: []) == .next)
    }
}
