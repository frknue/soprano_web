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

    @Test func stripDropLandsInTheGapNearestThePointer() {
        // Four visible tabs, 150 pt apart, after the 76 pt traffic lights.
        func index(_ x: CGFloat, start: Int = 0, visible: Int = 4) -> Int {
            BrowserTabReorder.stripInsertionIndex(
                x: x, leading: 76, tabWidth: 150, visibleStart: start, visibleCount: visible
            )
        }
        #expect(index(10) == 0)
        #expect(index(76 + 74) == 0)
        #expect(index(76 + 76) == 1)
        #expect(index(76 + 300) == 2)
        #expect(index(76 + 560) == 4)
        #expect(index(2_000) == 4)
        // Scrolled: tabs 3…6 are visible, so the first gap shown is gap 3.
        #expect(index(80, start: 3) == 3)
        #expect(index(76 + 160, start: 3) == 4)
    }

    @Test func railDropLandsInTheGapNearestThePointer() {
        // 32 pt rows with 4 pt spacing.
        #expect(BrowserTabReorder.railInsertionIndex(y: -20, rowPitch: 36, count: 3) == 0)
        #expect(BrowserTabReorder.railInsertionIndex(y: 10, rowPitch: 36, count: 3) == 0)
        #expect(BrowserTabReorder.railInsertionIndex(y: 20, rowPitch: 36, count: 3) == 1)
        #expect(BrowserTabReorder.railInsertionIndex(y: 80, rowPitch: 36, count: 3) == 2)
        #expect(BrowserTabReorder.railInsertionIndex(y: 100, rowPitch: 36, count: 3) == 3)
        #expect(BrowserTabReorder.railInsertionIndex(y: 900, rowPitch: 36, count: 3) == 3)
        #expect(BrowserTabReorder.railInsertionIndex(y: 50, rowPitch: 36, count: 0) == 0)
    }

    @Test func droppingBackIntoItsOwnListAccountsForItsOldSlot() {
        // Tab at 1 dropped into gap 3 (between the third and fourth tab)
        // ends up at index 2 once it has left index 1.
        #expect(BrowserTabReorder.moveIndex(forInsertion: 3, from: 1) == 2)
        #expect(BrowserTabReorder.moveIndex(forInsertion: 0, from: 2) == 0)
        #expect(BrowserTabReorder.moveIndex(forInsertion: 2, from: 2) == 2)
        let order = ["a", "b", "c", "d"]
        let index = BrowserTabReorder.moveIndex(forInsertion: 3, from: 1)
        #expect(BrowserTabReorder.moving("b", to: index, in: order) == ["a", "c", "b", "d"])
    }
}
