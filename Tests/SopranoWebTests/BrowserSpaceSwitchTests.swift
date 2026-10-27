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

    @Test func swipingLeftShowsTheNextSpaceOncePerGesture() {
        var swipe = BrowserSpaceSwipe()
        // Without natural scrolling, fingers moving left scroll right.
        #expect(swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 30, deltaY: 2, invertedFromDevice: false) == nil)
        #expect(swipe.isSwiping)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 40, deltaY: 1, invertedFromDevice: false) == .next)
        // The rest of the gesture switches nothing more.
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 90, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(swipe.isSwiping)
        #expect(swipe.scroll(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: false) == nil)
        #expect(!swipe.isSwiping)
        // With natural scrolling the deltas follow the fingers: right is
        // the previous Space.
        _ = swipe.scroll(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0, invertedFromDevice: true)
        #expect(swipe.scroll(phase: .changed, momentumPhase: [], deltaX: 70, deltaY: 0, invertedFromDevice: true) == .previous)
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
}
