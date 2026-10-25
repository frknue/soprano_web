@testable import SopranoWeb
import AppKit
import Testing

struct BrowserWindowMergeTests {
    @Test func aWindowsSelectedTabLeavesLast() {
        // Taking the selected tab out first would select (and load) the next one.
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b", "c"], selected: "b") == ["a", "c", "b"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b", "c"], selected: "c") == ["a", "b", "c"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b"], selected: nil) == ["a", "b"])
        #expect(BrowserWindowMerge.detachOrder(tabs: ["a", "b"], selected: "z") == ["a", "b"])
    }
}
