@testable import SopranoWeb
import AppKit
import Testing

/// P5 review fixes (P1-1, P2-1–P2-3, P3-1, P3-2) through a real window
/// manager (off-screen windows, a temporary support folder).
@MainActor
@Suite(.serialized)
struct BrowserSplitReviewTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSplitReview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let spaces = BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: directory.appendingPathComponent("bookmarks.json")
        )
        let defaults = UserDefaults(suiteName: "com.soprano.web.tests.\(UUID().uuidString)")!
        let manager = BrowserWindowManager(
            themeManager: ThemeManager(themeId: "folio", appearance: .light),
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"), settings: .default),
            profiles: profiles,
            supportDirectory: directory,
            spaces: spaces,
            archive: BrowserArchiveStore(url: directory.appendingPathComponent("archive.json")),
            downloads: BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json")),
            faviconStore: BrowserFaviconStore(directory: directory.appendingPathComponent("Favicons", isDirectory: true)),
            sessionStore: BrowserSessionStore(url: directory.appendingPathComponent("session.json")),
            persistsSession: false,
            placement: .offscreen(size: NSSize(width: 1200, height: 800)),
            defaults: defaults,
            filterLists: [],
            extensionStorage: .volatile,
            checksExtensionUpdates: false
        )
        return Fixture(manager: manager, directory: directory)
    }

    /// P1-1: a drag step swaps only the widths; the dragged divider stays.
    @Test func draggingADividerKeepsItAndResizesEveryStep() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        try #require(window.addSplitPane(url: "https://b.example/", commandBar: false) != nil)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let divider = try #require(window.splitPage.dividers.first)
        let width = window.webArea.bounds.width
        try #require(width > 0)
        let before = try #require(window.shownSplit?.ratios)
        window.resizeSplit(divider: 0, centerX: width * 0.3)
        let first = try #require(window.shownSplit?.ratios)
        #expect(first != before)
        window.resizeSplit(divider: 0, centerX: width * 0.65)
        let second = try #require(window.shownSplit?.ratios)
        #expect(second != first)
        #expect(window.splitPage.dividers.first === divider)
        #expect(divider.superview != nil)
        #expect(window.splitPage.widthConstraints.count == 1)
        #expect(abs((window.splitPage.widthConstraints.first?.multiplier ?? 0) - CGFloat(second[0])) < 0.0001)
    }

    /// P2-1: a favorite's live tab brought in from another Space leaves its
    /// split. A Space has a profile of its own, so the tab's Space is set by
    /// hand to stand for one recorded elsewhere.
    @Test func openingAFavoritePaneFromAnotherSpaceTakesItOutOfItsSplit() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let window = manager.newWindow()
        let spaceID = try #require(window.currentSpaceID)
        let favorite = try #require(manager.spaces.addFavorite(url: "https://fav.example/", title: "Fav", ofProfile: window.profileID))
        window.openFavorite(favorite.id)
        let favoriteTab = try #require(window.selectedTab)
        let today = try #require(window.addSplitPane(url: "https://t.example/", commandBar: false))
        #expect(window.split(containing: favoriteTab.id) != nil)
        favoriteTab.spaceID = UUID()
        window.openFavorite(favorite.id)
        #expect(window.selectedTab === favoriteTab)
        #expect(favoriteTab.spaceID == spaceID)
        #expect(window.split(containing: favoriteTab.id) == nil)
        #expect(window.split(containing: today.id) == nil)
        #expect(today.webView.isHidden)
    }

    /// P2-2: a closed window's splits follow its filtered tabs.
    @Test func keepingTabsRemapsAndDropsSplits() {
        let x = BrowserTabState(url: "https://x.example/")
        let a = BrowserTabState(url: "https://a.example/")
        let b = BrowserTabState(url: "https://b.example/")
        var state = BrowserWindowState(tabs: [x, a, b], selectedIndex: 2)
        state.splits = [BrowserSplitState(tabs: [1, 2], ratios: [0.3, 0.7], focused: 1)]
        let withoutX = state.keepingTabs { $0.url != x.url }
        #expect(withoutX.splits == [BrowserSplitState(tabs: [0, 1], ratios: [0.3, 0.7], focused: 1)])
        #expect(state.keepingTabs { $0.url != a.url }.splits.isEmpty)
        var three = BrowserWindowState(tabs: [x, a, b], selectedIndex: 0)
        three.splits = [BrowserSplitState(tabs: [0, 1, 2], ratios: [0.5, 0.25, 0.25], focused: 1)]
        let kept = three.keepingTabs { $0.url != a.url }.splits
        #expect(kept.first?.tabs == [0, 1])
        #expect(kept.first?.focused == 0)
        #expect(kept.first.map { abs($0.ratios[0] - 2.0 / 3) < 0.0001 } == true)
    }

    /// P2-3: from a split whose focused pane is pinned, the walk moves on
    /// to the Today row after the split.
    @Test func theRailWalkLeavesASplitWithAPinnedFocusedPane() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let spaceID = try #require(window.currentSpaceID)
        let pin = try #require(fixture.manager.spaces.addPin(url: "https://pinned.example/", title: "P", inSpace: spaceID))
        window.openPin(pin.id)
        let pinned = try #require(window.selectedTab)
        try #require(window.addSplitPane(url: "https://t.example/", commandBar: false) != nil)
        let after = window.newTab(url: "https://u.example/")
        window.selectTab(id: pinned.id, focus: false)
        #expect(window.selectedTab === pinned)
        let split = try #require(window.split(containing: pinned.id))
        let rows = window.todayRows
        let splitRow = try #require(rows.firstIndex { $0.id == split.id })
        try #require(rows.indices.contains(splitRow + 1))
        let next = rows[splitRow + 1]
        window.walkRail(step: 1)
        #expect(window.split(containing: window.selectedTab?.id ?? UUID()) == nil)
        #expect(window.selectedTab?.id == next.id)
        #expect(next.id == after.id)
    }

    /// P3-1: `>>` on a pane moves its split's row, the panes together.
    @Test func movingAPaneMovesItsSplitRow() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://t1.example/")
        let t1 = try #require(window.selectedTab)
        let a = window.newTab(url: "https://a.example/")
        let b = try #require(window.addSplitPane(url: "https://b.example/", commandBar: false))
        let t2 = window.newTab(url: "https://t2.example/")
        let split = try #require(window.split(containing: a.id))
        #expect(split.tabIDs == [a.id, b.id])
        #expect(window.todayRows.map(\.id) == [t1.id, split.id, t2.id])
        #expect(window.moveSplitRow(containing: a.id, by: 1) == true)
        #expect(window.todayRows.map(\.id) == [t1.id, t2.id, split.id])
        #expect(window.split(containing: a.id)?.tabIDs == [a.id, b.id])
        #expect(window.moveSplitRow(containing: a.id, by: 1) == false)
        #expect(window.moveSplitRow(containing: t1.id, by: 1) == nil)
    }

    /// P3-2: Merge All Windows keeps a merged window's split.
    @Test func mergingWindowsKeepsTheirSplits() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let first = manager.newWindow(url: "https://one.example/")
        let second = manager.newWindow(url: "https://a.example/")
        let a = try #require(second.selectedTab)
        let b = try #require(second.addSplitPane(url: "https://b.example/", commandBar: false))
        let split = try #require(second.split(containing: a.id))
        manager.mergeAllWindows()
        let target = try #require(manager.controllers.first { $0.tabs.contains { $0 === a } })
        #expect(manager.controllers.count == 1)
        #expect(target.split(containing: b.id)?.id == split.id)
        #expect(target.split(containing: a.id)?.tabIDs == [a.id, b.id])
        _ = first
    }
}
