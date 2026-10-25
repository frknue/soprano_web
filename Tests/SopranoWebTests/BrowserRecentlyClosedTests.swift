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
        #expect(entry.reopenTarget(openWindows: [key, home]) == .window(home, index: 2))
    }

    @Test func reopenedTabWhoseWindowClosedGoesToTheKeyWindowEnd() {
        let key = UUID()
        let other = UUID()
        let entry = tab("a", window: UUID(), index: 2)
        #expect(entry.reopenTarget(openWindows: [key, other]) == .window(key, index: nil))
        #expect(tab("b").reopenTarget(openWindows: [key]) == .window(key, index: nil))
    }

    @Test func reopenedTabWithNoWindowOpenGetsANewWindow() {
        #expect(tab("a", window: UUID(), index: 0).reopenTarget(openWindows: []) == .newWindow)
    }

    @Test func reopenedWindowIsAlwaysANewWindow() {
        let key = UUID()
        let window = BrowserWindowState(id: key, tabs: [BrowserTabState(url: nil)])
        #expect(BrowserClosedEntry(.window(window)).reopenTarget(openWindows: [key]) == .newWindow)
    }

    @Test func aTabOfAnotherProfileReopensInTheKeyWindowInItsSpace() {
        // Every normal window holds every Space, so a Work tab whose window
        // closed goes to the key window (which switches to its Space).
        let work = UUID()
        let workSpace = UUID()
        let key = UUID()
        let entry = BrowserClosedEntry(
            .tab(BrowserTabState(url: "https://example.com/a", title: "a", spaceID: workSpace), windowID: UUID(), index: 1),
            profileID: work
        )
        #expect(entry.reopenTarget(openWindows: [key]) == .window(key, index: nil))
        guard case let .tab(state, _, _) = entry.content else { return }
        #expect(state.spaceID == workSpace)
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

    @Test func deletingAProfileDropsItsTabsAndItsTabsOfClosedWindows() {
        let work = UUID()
        let workSpace = UUID()
        let defaultSpace = UUID()
        var stack = BrowserRecentlyClosedStack()
        stack.push(tab("default"))
        stack.push(BrowserClosedEntry(.tab(BrowserTabState(url: nil, title: "work"), windowID: nil, index: nil), profileID: work))
        // A version 2 window of the profile: every tab is the profile's.
        stack.push(BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil, title: "w")], profileID: work))))
        // A window with tabs of both: the Work Space's tab leaves, the
        // selections follow their tabs.
        let mixed = BrowserWindowState(
            tabs: [
                BrowserTabState(url: "https://example.com/w", title: "w2", spaceID: workSpace),
                BrowserTabState(url: "https://example.com/d", title: "d2", spaceID: defaultSpace),
            ],
            selectedIndex: 1,
            profileID: work,
            currentSpaceID: workSpace,
            spaceSelections: [
                BrowserSpaceSelection(spaceID: workSpace, index: 0),
                BrowserSpaceSelection(spaceID: defaultSpace, index: 1),
            ]
        )
        stack.push(BrowserClosedEntry(.window(mixed)))
        stack.removeEntries(ofProfile: work, spaces: [workSpace])
        #expect(stack.newestFirst.map(\.title) == ["d2 — 1 tab", "default"])
        guard case let .window(kept) = stack.newest?.content else {
            Issue.record("the mixed window stays")
            return
        }
        #expect(kept.tabs.map(\.title) == ["d2"])
        #expect(kept.selectedIndex == 0)
        #expect(kept.spaceSelections == [BrowserSpaceSelection(spaceID: defaultSpace, index: 0)])
    }

    @Test func titlesFallBackToTheHostAndNewTab() {
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: "https://webkit.org/blog"), windowID: nil, index: nil)).title == "webkit.org")
        #expect(BrowserClosedEntry(.tab(BrowserTabState(url: nil), windowID: nil, index: nil)).title == "New Tab")
        #expect(BrowserClosedEntry(.window(BrowserWindowState(tabs: [BrowserTabState(url: nil)]))).title == "New Tab — 1 tab")
    }
}
