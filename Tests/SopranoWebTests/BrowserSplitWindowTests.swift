@testable import SopranoWeb
import AppKit
import Testing

/// Split View through a real window manager (off-screen windows, a
/// temporary support folder; pages are not loaded), plus the P4 review
/// fixes that live in the same window code.
@MainActor
@Suite(.serialized)
struct BrowserSplitWindowTests {
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
            .appendingPathComponent("SopranoWebSplit-\(UUID().uuidString)", isDirectory: true)
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

    @Test func addingPanesShowsThemSideBySideAsOneRow() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let first = try #require(window.selectedTab)
        let second = try #require(window.addSplitPane(url: "https://b.example/", commandBar: false))
        #expect(window.selectedTab === second)
        #expect(window.shownSplit?.tabIDs == [first.id, second.id])
        #expect(!first.webView.isHidden && !second.webView.isHidden)
        #expect(window.todayRows == [.split(window.shownSplit!.id)])
        #expect(window.stripRows.count == 1)
        #expect(window.automationTabLines().last?.hasSuffix("split 1, pane 2 of 2") == true)
        // The other pane is visible: never idle.
        #expect(window.sleepExemption(first) == .visiblePane)
        #expect(window.archiveCandidate(first).activity.isVisiblePane)
        // At most 4 panes.
        window.addSplitPane(commandBar: false)
        window.addSplitPane(commandBar: false)
        #expect(window.shownSplit?.tabIDs.count == 4)
        #expect(window.addSplitPane(commandBar: false) == nil)
        #expect(!BrowserCommandID.splitAdd.command.state(BrowserCommandContext(manager: fixture.manager, controller: window)).isEnabled)
    }

    @Test func indexCommandsSelectAPaneAndFocusIt() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let first = try #require(window.selectedTab)
        let other = window.newTab(url: "https://other.example/", select: false)
        let pane = try #require(window.addSplitPane(url: "https://b.example/", commandBar: false))
        window.selectTab(id: other.id, focus: false)
        #expect(window.shownSplit == nil)
        #expect(first.webView.isHidden && pane.webView.isHidden)
        // ⌘1 counts tabs: tab 1 is a pane, so its split shows, focused on it.
        window.selectTab(number: 1)
        #expect(window.selectedTab === first)
        #expect(window.shownSplit?.focusedTabID == first.id)
        #expect(!pane.webView.isHidden)
        // ⌃⇧2 focuses pane 2; a split row selects its focused pane.
        #expect(window.focusPane(number: 2))
        #expect(window.selectedTab === pane)
        window.selectTab(id: other.id, focus: false)
        window.selectTab(id: window.splits[0].id, focus: false)
        #expect(window.selectedTab === pane)
        #expect(!window.focusPane(number: 3))
    }

    @Test func closingTheFocusedPaneFocusesItsNeighborAndCollapses() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let first = try #require(window.selectedTab)
        let second = try #require(window.addSplitPane(url: "https://b.example/", commandBar: false))
        let third = try #require(window.addSplitPane(url: "https://c.example/", commandBar: false))
        window.selectTab(id: second.id, focus: false)
        window.closeFocusedPane()
        #expect(window.selectedTab === third)
        #expect(window.shownSplit?.tabIDs == [first.id, third.id])
        window.closeFocusedPane()
        #expect(window.splits.isEmpty)
        #expect(window.selectedTab === first)
        #expect(window.shownSplit == nil)
        #expect(!BrowserCommandID.splitClose.command.state(BrowserCommandContext(manager: fixture.manager, controller: window)).isEnabled)
    }

    @Test func splitsRoundTripThroughTheSession() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        window.addSplitPane(url: "https://b.example/", commandBar: false)
        #expect(window.setSplitRatios([0.3, 0.7]))
        let state = window.windowState
        #expect(state.splits.count == 1)
        #expect(state.splits[0].ratios == [0.3, 0.7])
        let restored = fixture.manager.newWindow()
        restored.restoreTabs(state)
        let split = try #require(restored.splits.first)
        #expect(split.ratios == [0.3, 0.7])
        #expect(split.tabIDs.compactMap { id in restored.tabs.first { $0.id == id }?.state.url }
            == ["https://a.example/", "https://b.example/"])
    }

    @Test func aTabDroppedOnAPageEdgeJoinsThere() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let anchor = try #require(window.selectedTab)
        let dragged = window.newTab(url: "https://b.example/", select: false)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let width = window.webArea.bounds.width
        #expect(window.splitDropTarget(id: dragged.id, x: width / 2) == nil)
        #expect(window.splitDropTarget(id: anchor.id, x: 4) == nil)
        let insertion = try #require(window.splitDropTarget(id: dragged.id, x: 4))
        #expect(insertion == 0)
        #expect(window.dropTabOnPage(id: dragged.id, at: insertion))
        #expect(window.shownSplit?.tabIDs == [dragged.id, anchor.id])
        #expect(window.selectedTab === dragged)
    }

    // MARK: - P4 review fixes

    @Test func menuTitlesGoBackAfterThePeekCloses() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        let close = BrowserCommandID.closeTab.command
        window.openPeek(URL(string: "https://peek.example/")!, from: window.selectedTab!)
        #expect(close.menuTitle(for: close.state(context)) == "Close Peek")
        window.closePeek()
        #expect(close.menuTitle(for: close.state(context)) == "Close Tab")
        let open = BrowserCommandID.openInSpaceWindow.command
        #expect(open.menuTitle(for: open.state(context)) == open.title)
    }

    @Test func pageCommandsAndExtensionsFollowThePeek() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = try #require(window.selectedTab)
        let peekTab = window.openPeek(URL(string: "https://peek.example/")!, from: opener)
        #expect(window.pageTab === peekTab)
        // ⌘[ / ⌘] / ⌘. state, the zoom chip and extension actions read the page shown.
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(BrowserCommandID.back.command.state(context).isEnabled == peekTab.webView.canGoBack)
        window.closePeek()
        #expect(window.pageTab === opener)
    }

    @Test func escInAPeekClosesTheFindBarFirstAndClosingHidesIt() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let peekTab = window.openPeek(URL(string: "https://peek.example/")!, from: window.selectedTab!)
        window.showFindBar()
        window.vimiumFindActive = false
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
        #expect(!window.closesPeek(on: esc, in: peekTab))
        #expect(window.peek != nil)
        window.closePeek()
        #expect(window.findBar.isHidden)
    }
}
