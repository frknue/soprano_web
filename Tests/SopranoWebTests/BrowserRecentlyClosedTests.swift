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

    private func open(_ id: UUID, profile: UUID = BrowserProfile.defaultID) -> BrowserReopenWindow {
        BrowserReopenWindow(id: id, profileID: profile)
    }

    @Test func reopenedTabGoesBackToItsWindowAtItsIndex() {
        let home = UUID()
        let key = UUID()
        let entry = tab("a", window: home, index: 2)
        #expect(entry.reopenTarget(openWindows: [open(key), open(home)]) == .window(home, index: 2))
    }

    @Test func reopenedTabWhoseWindowClosedGoesToTheKeyWindowEnd() {
        let key = UUID()
        let other = UUID()
        let entry = tab("a", window: UUID(), index: 2)
        #expect(entry.reopenTarget(openWindows: [open(key), open(other)]) == .window(key, index: nil))
        #expect(tab("b").reopenTarget(openWindows: [open(key)]) == .window(key, index: nil))
    }

    @Test func reopenedTabWithNoWindowOpenGetsANewWindow() {
        #expect(tab("a", window: UUID(), index: 0).reopenTarget(openWindows: []) == .newWindow)
    }

    @Test func reopenedWindowIsAlwaysANewWindow() {
        let key = UUID()
        let window = BrowserWindowState(id: key, tabs: [BrowserTabState(url: nil)])
        #expect(BrowserClosedEntry(.window(window)).reopenTarget(openWindows: [open(key)]) == .newWindow)
    }

    @Test func reopenedTabGoesOnlyIntoAWindowOfItsProfile() {
        let work = UUID()
        let defaultKey = UUID()
        let workWindow = UUID()
        let entry = BrowserClosedEntry(
            .tab(BrowserTabState(url: "https://example.com/a", title: "a"), windowID: UUID(), index: 1),
            profileID: work
        )
        // The key window is a Default window; the tab goes to the most
        // recently active Work window instead.
        let windows = [open(defaultKey), open(workWindow, profile: work)]
        #expect(entry.reopenTarget(openWindows: windows) == .window(workWindow, index: nil))
        // With no Work window open it gets a new (Work) window.
        #expect(entry.reopenTarget(openWindows: [open(defaultKey)]) == .newWindow)
    }

    @Test func reopenedTabIgnoresItsOldWindowIdInAnotherProfile() {
        let work = UUID()
        let reused = UUID()
        let entry = BrowserClosedEntry(.tab(BrowserTabState(url: nil), windowID: reused, index: 0), profileID: work)
        #expect(entry.reopenTarget(openWindows: [open(reused)]) == .newWindow)
    }

    @Test func entriesRememberTheirProfileAcrossTheSessionFile() throws {
        let work = UUID()
        let tabEntry = BrowserClosedEntry(.tab(BrowserTabState(url: "https://example.com/t", title: "T"), windowID: nil, index: nil), profileID: work)
        let windowEntry = BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil)], profileID: work)))
        #expect(windowEntry.profileID == work)
        let data = try JSONEncoder().encode([tabEntry, windowEntry])
        let decoded = try JSONDecoder().decode([BrowserClosedEntry].self, from: data)
        #expect(decoded == [tabEntry, windowEntry])
        #expect(decoded.map(\.profileID) == [work, work])

        // An entry saved before profiles existed belongs to Default.
        let old = #"{"id":"\#(UUID().uuidString)","kind":"tab","tab":{"url":"https://example.com/old","title":"Old"}}"#
        let legacy = try JSONDecoder().decode(BrowserClosedEntry.self, from: Data(old.utf8))
        #expect(legacy.profileID == BrowserProfile.defaultID)
    }

    @Test func deletingAProfileDropsOnlyItsEntries() {
        let work = UUID()
        var stack = BrowserRecentlyClosedStack()
        stack.push(tab("default"))
        stack.push(BrowserClosedEntry(.tab(BrowserTabState(url: nil, title: "work"), windowID: nil, index: nil), profileID: work))
        stack.push(BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil, title: "w")], profileID: work))))
        stack.removeAll { $0.profileID == work }
        #expect(stack.newestFirst.map(\.title) == ["default"])
    }

    @Test func titlesFallBackToTheHostAndNewTab() {
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: "https://webkit.org/blog"), windowID: nil, index: nil)).title == "webkit.org")
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: nil), windowID: nil, index: nil)).title == "New Tab")
        #expect(BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil)]))).title == "New Tab — 1 tab")
    }
}
