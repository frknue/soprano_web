@testable import SopranoWeb
import AppKit
import Testing

struct BrowserRecentlyClosedTests {
    private func tab(_ path: String, window: UUID? = nil, index: Int? = nil) -> BrowserClosedEntry {
        BrowserClosedEntry(.tab(BrowserTabState(url: "https://example.com/\(path)", title: path), windowID: window, index: index))
    }

    @Test func reopensNewestFirstAndListsNewestFirst() {
        var stack = BrowserRecentlyClosedStack()
        let window = BrowserWindowState(
            tabs: [BrowserTabState(url: "https://webkit.org", title: "WebKit"), BrowserTabState(url: nil)],
            selectedIndex: 0
        )
        stack.push(tab("a"))
        stack.push(BrowserClosedEntry(.window(window)))
        stack.push(tab("b"))

        #expect(stack.newestFirst.map(\.title) == ["b", "WebKit — 2 tabs", "a"])
        #expect(stack.newest?.title == "b")
        #expect(stack.pop()?.title == "b")
        #expect(stack.newest?.isWindow == true)
        #expect(stack.pop()?.content == .window(window))
        #expect(stack.pop()?.title == "a")
        #expect(stack.pop() == nil)
    }

    @Test func menuReopensAnyEntryAndLeavesTheRest() {
        var stack = BrowserRecentlyClosedStack()
        let middle = tab("b")
        stack.push(tab("a"))
        stack.push(middle)
        stack.push(tab("c"))
        #expect(stack.remove(id: middle.id) == middle)
        #expect(stack.remove(id: middle.id) == nil)
        #expect(stack.newestFirst.map(\.title) == ["c", "a"])
    }

    @Test func keepsTheTwentyMostRecentTabsAndWindows() {
        var stack = BrowserRecentlyClosedStack()
        for number in 1...25 {
            stack.push(number.isMultiple(of: 5)
                ? BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: "https://example.com/\(number)", title: "\(number)")])))
                : tab("\(number)"))
        }
        #expect(stack.count == BrowserRecentlyClosedStack.capacity)
        #expect(stack.newestFirst.last?.title == "6")
        #expect(stack.pop()?.title == "25 — 1 tab")

        let oversized = (1...30).map { tab("\($0)") }
        let loaded = BrowserRecentlyClosedStack(oversized)
        #expect(loaded.count == 20)
        #expect(loaded.entries.first?.title == "11")
    }

    @Test func reopenedTabGoesBackToItsWindowAtItsIndex() {
        let home = UUID()
        let key = UUID()
        let entry = tab("a", window: home, index: 2)
        #expect(entry.reopenTarget(openWindowIDs: [key, home], keyWindowID: key) == .window(home, index: 2))
    }

    @Test func reopenedTabWhoseWindowClosedGoesToTheKeyWindowEnd() {
        let key = UUID()
        let entry = tab("a", window: UUID(), index: 2)
        #expect(entry.reopenTarget(openWindowIDs: [key], keyWindowID: key) == .window(key, index: nil))
        #expect(tab("b").reopenTarget(openWindowIDs: [key], keyWindowID: key) == .window(key, index: nil))
    }

    @Test func reopenedTabWithNoWindowOpenGetsANewWindow() {
        #expect(tab("a", window: UUID(), index: 0).reopenTarget(openWindowIDs: [], keyWindowID: nil) == .newWindow)
    }

    @Test func reopenedWindowIsAlwaysANewWindow() {
        let key = UUID()
        let window = BrowserWindowState(id: key, tabs: [BrowserTabState(url: nil)])
        #expect(BrowserClosedEntry(.window(window)).reopenTarget(openWindowIDs: [key], keyWindowID: key) == .newWindow)
    }

    @Test func titlesFallBackToTheHostAndNewTab() {
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: "https://webkit.org/blog"), windowID: nil, index: nil)).title == "webkit.org")
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: nil), windowID: nil, index: nil)).title == "New Tab")
        #expect(BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil)]))).title == "New Tab — 1 tab")
    }
}
