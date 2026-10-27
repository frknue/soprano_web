@testable import SopranoWeb
import AppKit
import Testing

/// The split model, layout and drop math, rows, session state and the
/// ⌥-click disposition (pure), then splits through a real window manager.
struct BrowserSplitModelTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func aSplitNeedsTwoDistinctTabsAndKeepsAtMostFour() {
        #expect(BrowserSplit(tabIDs: [a]) == nil)
        #expect(BrowserSplit(tabIDs: [a, a]) == nil)
        let split = BrowserSplit(tabIDs: [a, b, c, d, e])!
        #expect(split.tabIDs == [a, b, c, d])
        #expect(split.ratios == [0.25, 0.25, 0.25, 0.25])
        #expect(split.focusedTabID == a)
        #expect(split.isFull)
        #expect(split.inserting(e, at: 0) == nil)
    }

    @Test func addingAPaneTakesAnEqualShareAndFocus() {
        let split = BrowserSplit(tabIDs: [a, b], ratios: [0.6, 0.4])!
        let three = split.inserting(c, at: 1)!
        #expect(three.tabIDs == [a, c, b])
        #expect(three.focusedTabID == c)
        #expect(abs(three.ratios[1] - 1.0 / 3) < 1e-9)
        #expect(abs(three.ratios[0] - 0.4) < 1e-9)
        #expect(abs(three.ratios.reduce(0, +) - 1) < 1e-9)
        #expect(split.inserting(a, at: 0) == nil)
    }

    @Test func removingPanesCollapsesToASingleTab() {
        let split = BrowserSplit(tabIDs: [a, b, c], ratios: [0.5, 0.25, 0.25], focusedTabID: b)!
        let two = split.removing(b)!
        #expect(two.tabIDs == [a, c])
        #expect(two.focusedTabID == c)
        #expect(abs(two.ratios[0] - 2.0 / 3) < 1e-9)
        #expect(two.removing(a) == nil)
        #expect(two.removing(e) == two)
    }

    @Test func dividersResizeOnlyTheirNeighborsWithinTheMinimum() {
        let split = BrowserSplit(tabIDs: [a, b, c])!
        let resized = split.resizing(divider: 0, to: 0.5, minimum: 0.1)
        #expect(abs(resized.ratios[0] - 0.5) < 1e-9)
        #expect(abs(resized.ratios[1] - (2.0 / 3 - 0.5)) < 1e-9)
        #expect(abs(resized.ratios[2] - 1.0 / 3) < 1e-9)
        let clamped = split.resizing(divider: 0, to: 0.99, minimum: 0.1)
        #expect(abs(clamped.ratios[1] - 0.1) < 1e-9)
        #expect(split.resizing(divider: 2, to: 0.5, minimum: 0.1) == split)
        #expect(BrowserSplit(tabIDs: [a, b])!.minimumShare(width: 1006) == 0.24)
    }

    @Test func paneFramesAndDividerPositionsMatch() {
        let frames = BrowserSplitLayout.paneFrames(width: 1006, ratios: [0.5, 0.5], gap: 6)
        #expect(frames.map(\.x) == [0, 506])
        #expect(frames.map(\.width) == [500, 500])
        let position = BrowserSplitLayout.dividerPosition(centerX: 503, divider: 0, width: 1006, panes: 2, gap: 6)
        #expect(abs(position - 0.5) < 1e-9)
    }

    @Test func dropEdgeMath() {
        // One page 1000 wide: the outer quarter (at most 160) of each side.
        #expect(BrowserSplitDrop.insertion(atX: 10, width: 1000, ratios: [1]) == 0)
        #expect(BrowserSplitDrop.insertion(atX: 500, width: 1000, ratios: [1]) == nil)
        #expect(BrowserSplitDrop.insertion(atX: 950, width: 1000, ratios: [1]) == 1)
        #expect(BrowserSplitDrop.insertion(atX: 170, width: 1000, ratios: [1]) == nil)
        // Two panes: the inner edges join between them.
        #expect(BrowserSplitDrop.insertion(atX: 450, width: 1006, ratios: [0.5, 0.5], gap: 6) == 1)
        #expect(BrowserSplitDrop.insertion(atX: 520, width: 1006, ratios: [0.5, 0.5], gap: 6) == 1)
        #expect(BrowserSplitDrop.insertion(atX: 503, width: 1006, ratios: [0.5, 0.5], gap: 6) == nil)
        #expect(BrowserSplitDrop.insertion(atX: 1000, width: 1006, ratios: [0.5, 0.5], gap: 6) == 2)
    }

    @Test func rowsShowASplitOnceAndReorderItsPanesTogether() {
        let pin = UUID()
        let split = BrowserSplit(tabIDs: [c, a])!
        let tabs = [(id: pin, isToday: false), (id: a, isToday: true), (id: b, isToday: true), (id: c, isToday: true)]
        #expect(BrowserTabRows.today(tabs, splits: [split]) == [.split(split.id), .tab(b)])
        #expect(BrowserTabRows.strip(tabs, splits: [split]) == [.tab(pin), .split(split.id), .tab(b)])
        let order = BrowserTabRows.todayOrder(
            moving: split.id, to: 1, rows: [.split(split.id), .tab(b)], todayIDs: [a, b, c], splits: [split]
        )
        #expect(order == [b, c, a])
        // A split of linked panes only comes first in the Today rows.
        let linked = BrowserSplit(tabIDs: [pin, d])!
        let more = tabs + [(id: d, isToday: false)]
        #expect(BrowserTabRows.today(more, splits: [linked]).first == .split(linked.id))
    }

    @Test func sessionStateRoundTripsAndRestoresOnlyValidSplits() throws {
        let split = BrowserSplit(tabIDs: [b, c], ratios: [0.3, 0.7], focusedTabID: c)!
        let state = try #require(split.state(windowTabs: [a, b, c]))
        #expect(state == BrowserSplitState(tabs: [1, 2], ratios: [0.3, 0.7], focused: 1))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(BrowserSplitState.self, from: data) == state)
        let space = UUID()
        let restored = BrowserSplit.restored(
            [state, BrowserSplitState(tabs: [1, 0], ratios: []), BrowserSplitState(tabs: [0, 9], ratios: [])],
            tabIDs: [d, e, a],
            spaceIDs: [space, space, space]
        )
        #expect(restored.count == 1)
        #expect(restored[0].tabIDs == [e, a])
        #expect(restored[0].focusedTabID == a)
        #expect(BrowserSplit.restored([state], tabIDs: [d, e, a], spaceIDs: [space, space, UUID()]).isEmpty)
    }

    @Test func olderSessionsHaveNoSplitsAndVersionFiveKeepsThem() throws {
        let old = Data(#"{"version":4,"windows":[{"tabs":[{"url":"https://a.example/"}]}],"savedAt":0}"#.utf8)
        let session = try JSONDecoder().decode(BrowserSession.self, from: old)
        #expect(session.version == 4)
        #expect(session.windows.first?.splits == [])
        var window = BrowserWindowState(tabs: [BrowserTabState(url: "https://a.example/"), BrowserTabState(url: "https://b.example/")])
        window.splits = [BrowserSplitState(tabs: [0, 1], ratios: [0.5, 0.5], focused: 1)]
        let current = BrowserSession(windows: [window], savedAt: Date(timeIntervalSince1970: 0))
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(current))
        #expect(BrowserSession.currentVersion == 5)
        #expect(decoded.windows.first?.splits == window.splits)
    }

    @Test func optionClickOpensAPaneForWebLinksOnly() {
        let web = URL(string: "https://example.com/")
        func disposition(_ flags: NSEvent.ModifierFlags, _ link: URL?) -> BrowserLinkDisposition {
            BrowserLinkDisposition.disposition(
                modifierFlags: flags, buttonNumber: 1, origin: .today,
                pageURL: URL(string: "https://page.example/"), linkURL: link, targetsMainFrame: true
            )
        }
        #expect(disposition(.option, web) == .splitPane)
        #expect(disposition(.option, URL(string: "mailto:a@b.c")) == .currentTab)
        #expect(disposition([.option, .command], web) == .backgroundTab)
        #expect(disposition([.shift, .option], web) == .peek)
        // P3-5: scripted window.open never becomes a Peek or a pane.
        #expect(BrowserLinkDisposition.scriptedDisposition(modifierFlags: .shift, buttonNumber: 1) == .currentTab)
        #expect(BrowserLinkDisposition.scriptedDisposition(modifierFlags: .option, buttonNumber: 1) == .currentTab)
        #expect(BrowserLinkDisposition.scriptedDisposition(modifierFlags: .command, buttonNumber: 1) == .backgroundTab)
        #expect(disposition(.shift, URL(string: "about:blank")) == .currentTab)
    }

    @Test func visiblePanesNeverSleepOrArchive() {
        let pane = BrowserTabSleepCandidate(isVisiblePane: true, lastActive: .distantPast)
        #expect(BrowserTabSleepPolicy.exemption(for: pane) == .visiblePane)
        let archive = BrowserArchiveCandidate(activity: pane)
        #expect(BrowserArchivePolicy.exemption(for: archive) == .visiblePane)
        #expect(!BrowserArchivePolicy.shouldArchive(archive, now: Date(), archiveAfter: .hour1))
    }

    @Test func theGlobalChordIsReservedWhileOnAndATakenFallbackTurnsItOff() throws {
        var settings = BrowserSettings()
        settings.globalLittleArcEnabled = true
        settings.globalLittleArcShortcut = "ctrl+opt+space"
        let chord = try #require(BrowserShortcut("ctrl+opt+space"))
        #expect(BrowserGlobalShortcut.owner(of: chord, for: .newTab, settings: settings) == "Little Arc anywhere")
        #expect(BrowserGlobalShortcut.owner(of: chord, for: .newLittleArc, settings: settings) == nil)
        settings.globalLittleArcEnabled = false
        #expect(BrowserGlobalShortcut.owner(of: chord, for: .newTab, settings: settings) == nil)
        // ⌥⌘N given to New Tab, and a taken stored chord: the hotkey stays off.
        let json = Data(#"{"globalLittleArcEnabled": true, "globalLittleArcShortcut": "cmd+c", "shortcuts": {"new-tab": {"shortcut": "opt+cmd+n"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: json)
        if decoded.keymap.command(for: try #require(BrowserShortcut("opt+cmd+n"))) == .newTab {
            #expect(!decoded.globalLittleArcEnabled)
        }
    }
}
