@testable import SopranoWeb
import AppKit
import Testing

struct BrowserTabReorderTests {
    @Test func slotUnderThePointerClampsToTheEnds() {
        #expect(BrowserTabReorder.slot(at: -30, pitch: 100, count: 4) == 0)
        #expect(BrowserTabReorder.slot(at: 0, pitch: 100, count: 4) == 0)
        #expect(BrowserTabReorder.slot(at: 99.9, pitch: 100, count: 4) == 0)
        #expect(BrowserTabReorder.slot(at: 100, pitch: 100, count: 4) == 1)
        #expect(BrowserTabReorder.slot(at: 399, pitch: 100, count: 4) == 3)
        #expect(BrowserTabReorder.slot(at: 5_000, pitch: 100, count: 4) == 3)
    }

    @Test func slotIsZeroWithoutSlotsOrPitch() {
        #expect(BrowserTabReorder.slot(at: 50, pitch: 36, count: 0) == 0)
        #expect(BrowserTabReorder.slot(at: 50, pitch: 0, count: 3) == 0)
        #expect(BrowserTabReorder.slot(at: .nan, pitch: 36, count: 3) == 0)
    }

    @Test func movingPlacesTheTabAtTheTargetIndex() {
        let order = ["a", "b", "c", "d"]
        #expect(BrowserTabReorder.moving("a", to: 2, in: order) == ["b", "c", "a", "d"])
        #expect(BrowserTabReorder.moving("d", to: 0, in: order) == ["d", "a", "b", "c"])
        #expect(BrowserTabReorder.moving("b", to: 99, in: order) == ["a", "c", "d", "b"])
        #expect(BrowserTabReorder.moving("c", to: -1, in: order) == ["c", "a", "b", "d"])
        #expect(BrowserTabReorder.moving("c", to: 2, in: order) == order)
        #expect(BrowserTabReorder.moving("z", to: 1, in: order) == order)
    }
}
