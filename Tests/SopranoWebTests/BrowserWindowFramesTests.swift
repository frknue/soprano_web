@testable import SopranoWeb
import AppKit
import Testing

struct BrowserWindowFramesTests {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
    private let minSize = NSSize(width: 760, height: 520)

    @Test func frameOnAScreenStaysWhereItWas() {
        let frame = NSRect(x: 1700, y: 200, width: 1400, height: 900)
        #expect(BrowserWindowFrames.clamped(frame, to: [laptop, external], minSize: minSize) == frame)
    }

    @Test func frameFromADisconnectedScreenMovesOntoTheFirstScreen() {
        let frame = NSRect(x: 5000, y: 300, width: 1200, height: 800)
        let clamped = BrowserWindowFrames.clamped(frame, to: [laptop], minSize: minSize)
        #expect(clamped == NSRect(x: 312, y: 144, width: 1200, height: 800))
    }

    @Test func oversizedFrameShrinksToItsScreenButNotBelowTheMinimum() {
        let frame = NSRect(x: 1400, y: -50, width: 3000, height: 2000)
        #expect(
            BrowserWindowFrames.clamped(frame, to: [laptop, external], minSize: minSize)
                == NSRect(x: 1512, y: 0, width: 2560, height: 1415)
        )
        let tiny = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(BrowserWindowFrames.clamped(tiny, to: [laptop], minSize: minSize).size == minSize)
    }

    @Test func newWindowCascadesFromTheKeyWindow() {
        let key = NSRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(
            BrowserWindowFrames.cascaded(from: key, screens: [laptop])
                == NSRect(x: 122, y: 78, width: 1200, height: 800)
        )
    }

    @Test func cascadeStartsOverAtTheTopLeftWhenItWouldLeaveTheScreen() {
        let key = NSRect(x: 300, y: 10, width: 1200, height: 800)
        #expect(
            BrowserWindowFrames.cascaded(from: key, screens: [laptop])
                == NSRect(x: 0, y: 144, width: 1200, height: 800)
        )
    }

    @Test func aTabDroppedOutsideOpensItsWindowUnderThePointer() {
        let point = NSPoint(x: 600, y: 700)
        let frame = BrowserWindowFrames.dropped(
            at: point,
            size: NSSize(width: 1000, height: 600),
            screens: [laptop],
            minSize: minSize
        )
        #expect(frame == NSRect(x: 500, y: 115, width: 1000, height: 600))
        #expect(frame.minX + BrowserWindowFrames.dropGrabOffset.x == point.x)
        #expect(frame.maxY - BrowserWindowFrames.dropGrabOffset.y == point.y)

        // Near the screen's edge the window stays on the screen.
        let edge = BrowserWindowFrames.dropped(
            at: NSPoint(x: 1500, y: 20),
            size: NSSize(width: 1000, height: 600),
            screens: [laptop],
            minSize: minSize
        )
        #expect(edge == NSRect(x: 512, y: 0, width: 1000, height: 600))
    }

    @Test func stageOneAutosavedFrameIsRead() {
        #expect(
            BrowserWindowFrames.autosavedFrame("120 80 1300 820 0 0 1512 944 ")
                == NSRect(x: 120, y: 80, width: 1300, height: 820)
        )
        #expect(BrowserWindowFrames.autosavedFrame(nil) == nil)
        #expect(BrowserWindowFrames.autosavedFrame("garbage") == nil)
    }
}
