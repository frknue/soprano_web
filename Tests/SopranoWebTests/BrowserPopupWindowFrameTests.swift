@testable import SopranoWeb
import AppKit
import Testing

struct BrowserPopupWindowFrameTests {
    /// A laptop's visible frame below a 25 pt menu bar, and an external screen.
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 919)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
    private let opener = NSRect(x: 100, y: 100, width: 1200, height: 800)
    private let chrome: CGFloat = 46

    @Test func onlyASizeOpensAWindow() {
        #expect(BrowserPopupFeatures(width: 480, height: 640).opensWindow)
        #expect(BrowserPopupFeatures(width: 480).opensWindow)
        #expect(BrowserPopupFeatures(height: 640).opensWindow)
        #expect(!BrowserPopupFeatures().opensWindow)
        #expect(!BrowserPopupFeatures(left: 10, top: 10).opensWindow)
    }

    @Test func requestedSizeIsThePageAreaCenteredOnTheOpener() {
        let frame = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 480, height: 640),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop]
        )
        #expect(frame.size == NSSize(width: 480, height: 640 + chrome))
        #expect(frame.midX == opener.midX)
        #expect(frame.midY == opener.midY)
    }

    @Test func leftAndTopCountFromTheMainScreensTopLeft() {
        let frame = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 500, height: 400, left: 200, top: 100),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop, external]
        )
        #expect(frame == NSRect(x: 200, y: 919 - 100 - 446, width: 500, height: 446))
    }

    @Test func aMissingSideComesFromTheOpener() {
        let frame = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 600),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop]
        )
        #expect(frame.size == NSSize(width: 600, height: 800))
    }

    @Test func tinyRequestsGetTheMinimum() {
        let frame = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 20, height: 10),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop]
        )
        #expect(frame.size == NSSize(
            width: BrowserPopupWindowFrame.minimumContentSize.width,
            height: BrowserPopupWindowFrame.minimumContentSize.height + chrome
        ))
    }

    @Test func hugeOrOffscreenRequestsStayOnTheScreen() {
        let huge = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 5_000, height: 4_000),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop]
        )
        #expect(huge == laptop)

        let offscreen = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(width: 480, height: 640, left: 9_000, top: -300),
            chromeHeight: chrome,
            opener: opener,
            screens: [laptop]
        )
        #expect(offscreen.size == NSSize(width: 480, height: 640 + chrome))
        #expect(laptop.contains(offscreen))
        #expect(offscreen.maxX == laptop.maxX)
        #expect(offscreen.maxY == laptop.maxY)
    }

    @Test func withoutAnOpenerItCentersOnTheMainScreen() {
        let frame = BrowserPopupWindowFrame.frame(
            for: BrowserPopupFeatures(height: 300),
            chromeHeight: chrome,
            opener: nil,
            screens: [laptop]
        )
        #expect(frame.size == NSSize(width: BrowserPopupWindowFrame.defaultContentSize.width, height: 300 + chrome))
        #expect(frame.midX == laptop.midX)
    }
}
