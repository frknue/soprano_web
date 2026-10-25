@testable import SopranoWeb
import AppKit
import Testing

struct BrowserWindowMergeTests {
    @Test func mergeAppendsEveryWindowInOrderAfterTheKeyWindow() {
        let merged = BrowserWindowMerge.merged(
            target: ["k1", "k2", "k3"],
            selectedIndex: 1,
            others: [["a1", "a2"], ["b1"], ["c1", "c2", "c3"]]
        )
        #expect(merged.tabs == ["k1", "k2", "k3", "a1", "a2", "b1", "c1", "c2", "c3"])
        // The key window's selected tab stays selected, at the same index.
        #expect(merged.tabs[merged.selectedIndex] == "k2")
    }

    @Test func mergeWithNoOtherWindowsChangesNothing() {
        let merged = BrowserWindowMerge.merged(target: ["k1"], selectedIndex: 0, others: [])
        #expect(merged.tabs == ["k1"])
        #expect(merged.selectedIndex == 0)
    }

    @Test func aWindowsSelectedTabLeavesLast() {
        // Taking the selected tab out first would select (and load) the next one.
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b", "c"], selected: "b") == ["a", "c", "b"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b", "c"], selected: "c") == ["a", "b", "c"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b"], selected: nil) == ["a", "b"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b"], selected: "z") == ["a", "b"])
    }
}
