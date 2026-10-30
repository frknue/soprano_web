@testable import SopranoWeb
import AppKit
import Testing

/// Live folders in a real window (off-screen, a temporary support folder,
/// a stand-in for `gh`): the rail's rows, opening a pull request, drops,
/// and New / Edit Live Folder in the pin editor.
@MainActor
@Suite(.serialized)
struct BrowserLiveFolderWindowTests {
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
            .appendingPathComponent("SopranoWebLiveWindow-\(UUID().uuidString)", isDirectory: true)
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
        let items = (1...2).map { number in
            BrowserPullRequest(
                number: number, title: "PR \(number)", url: "https://github.com/o/r/pull/\(number)",
                repository: "o/r", author: "a", isDraft: false, updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        manager.liveFolders.fetch = { _ in .success(items) }
        return Fixture(manager: manager, directory: directory)
    }

    private func liveWindow(_ fixture: Fixture) async throws -> (BrowserWindowController, BrowserPinFolder) {
        let window = fixture.manager.newWindow()
        let spaceID = try #require(window.pinSpaceID)
        let folder = try #require(fixture.manager.spaces.addLiveFolder(
            name: "PRs", source: .githubPullRequests(repo: "o/r"), inSpace: spaceID
        ))
        window.setPinFolderExpanded(folder.id, true)
        await fixture.manager.liveFolders.waitForFetches()
        return (window, folder)
    }

    @Test func theRailShowsAnOpenFoldersPullRequestsAndOpensThemAsTodayTabs() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (window, folder) = try await liveWindow(fixture)

        let rows = window.verticalTabsView.pinsView.rows
        #expect(rows.map(\.row.node.title) == ["PRs", "PR 1", "PR 2"])
        #expect(rows.first?.row.node.folder?.allPins.count == 2)
        #expect(rows.first?.liveFailed == false)

        let itemID = try #require(rows.last?.id)
        let before = window.visibleTabs.count
        window.openPin(itemID)
        let opened = try #require(window.selectedTab)
        #expect(opened.origin == .today)
        #expect(window.visibleTabs.count == before + 1)
        // A second open selects the tab instead of opening another.
        window.selectTab(id: window.visibleTabs[0].id, focus: false)
        window.openPin(itemID)
        #expect(window.selectedTab === opened)
        #expect(window.visibleTabs.count == before + 1)
        // The fetched rows are never pins of the Space.
        #expect(window.currentPinTree.folder(id: folder.id)?.children.isEmpty == true)
    }

    @Test func openAllInTabsKeepsTheFoldersOrderAndSelectsTheFirst() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (window, folder) = try await liveWindow(fixture)
        let before = window.todayTabs.count

        window.openBookmarkFolderInTabs(folder.id)
        let opened = window.todayTabs.dropFirst(before).map { $0.state.url ?? $0.item.url?.absoluteString ?? "" }
        #expect(opened == ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"])
        #expect(window.selectedTab === window.todayTabs[before])
    }

    @Test func openAllOnAPlainParentOpensItsLiveFoldersPullRequestsInOrder() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (window, folder) = try await liveWindow(fixture)
        let spaceID = try #require(window.pinSpaceID)
        let parent = try #require(fixture.manager.spaces.addPinFolder(name: "Work", inSpace: spaceID))
        #expect(fixture.manager.spaces.movePin(folder.id, to: parent.id, at: 0, inSpace: spaceID))
        let pin = try #require(fixture.manager.spaces.addPin(url: "https://example.com/", title: "Example", to: parent.id, inSpace: spaceID))
        let before = window.todayTabs.count

        // Work holds the pin (added first), then the live folder (PR 1, PR 2).
        window.openBookmarkFolderInTabs(parent.id)
        let opened = window.todayTabs.dropFirst(before).map { $0.state.url ?? $0.item.url?.absoluteString ?? "" }
        #expect(opened == ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"])
        let pinTab = try #require(window.liveTab(for: .pinned(pin.id)))
        #expect(window.selectedTab === pinTab)
    }

    @Test func aFetchAfterThePointerLeftDoesntBringThePreviewBack() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (window, folder) = try await liveWindow(fixture)
        window.setPinFolderExpanded(folder.id, false)
        let row = try #require(window.verticalTabsView.pinsView.rowView(for: folder.id))
        let frame = row.convert(row.bounds, to: window.verticalTabsView.pinsView)
        #expect(window.showFolderPreview(folder.id, rowFrame: frame) != nil)

        // The pointer leaves the row for the page; a fetch lands before the
        // preview's hide delay ends.
        window.folderHovered(nil, rowFrame: .zero)
        var state = try #require(fixture.manager.liveFolders.state(of: folder.id))
        state.items.removeLast()
        fixture.manager.liveFolders.setState(state, for: folder.id)
        #expect(window.folderPreview == nil)

        // While the pointer stays on the row, the preview shows the new list.
        #expect(window.showFolderPreview(folder.id, rowFrame: frame) != nil)
        state.items = []
        fixture.manager.liveFolders.setState(state, for: folder.id)
        #expect(window.folderPreview?.entries.isEmpty == true)
    }

    @Test func theCLIRefreshesWithNoWindowOpen() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let spaceID = try #require(fixture.manager.spaces.spaces.first?.id)
        fixture.manager.spaces.addLiveFolder(name: "PRs", source: .githubPullRequests(repo: "o/r"), inSpace: spaceID)
        #expect(fixture.manager.automationControllers.isEmpty)
        let request = try #require(try BrowserCommandRequest.parse(["soprano-web", "browser", "live-folder", "refresh"]))
        let output: String = try await withCheckedThrowingContinuation { continuation in
            BrowserAutomationRouter.perform(request, in: fixture.manager) { continuation.resume(with: $0) }
        }
        #expect(output.contains("PRs\tOpen pull requests in o/r\t2 pull requests"))
    }

    @Test func dropsIntoALiveFolderAreRefused() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let (window, folder) = try await liveWindow(fixture)
        let spaceID = try #require(window.pinSpaceID)
        let pin = try #require(fixture.manager.spaces.addPin(url: "https://example.com/", title: "Example", inSpace: spaceID))
        window.updateRail()
        let rows = window.verticalTabsView.pinsView.rows.map(\.row)
        let folderRow = try #require(rows.firstIndex { $0.node.id == folder.id })
        let itemRow = try #require(rows.firstIndex { $0.node.title == "PR 2" })

        #expect(window.bookmarkDestination(for: pin.id, drop: .on(folderRow)) == nil)
        #expect(window.bookmarkDestination(for: pin.id, drop: .above(itemRow)) == nil)
        #expect(!window.performBookmarkDrop(pin.id, drop: .above(itemRow)))
        // A pull request row isn't a pin: it never moves.
        #expect(window.bookmarkDestination(for: rows[itemRow].node.id, drop: .above(rows.count)) == nil)
        #expect(window.currentPinTree.folder(id: folder.id)?.children.isEmpty == true)
    }

    @Test func theEditorMakesAndEditsALiveFolder() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let spaceID = try #require(window.pinSpaceID)

        let new = try #require(window.makeLiveFolderEditor(editing: nil, parentID: BrowserPinTree.rootID, index: nil))
        #expect(new.content.heading == "New Live Folder")
        #expect(new.content.removeTitle == nil)
        new.onDone?("", "https://github.com/o/r")
        let made = try #require(fixture.manager.spaces.pinTree(inSpace: spaceID).liveFolders().first)
        #expect(made.source == .githubPullRequests(repo: "o/r"))
        #expect(fixture.manager.spaces.pinTree(inSpace: spaceID).folder(id: made.id)?.name == "o/r")
        #expect(fixture.manager.pinUIState.expandedFolders.contains(made.id))
        await fixture.manager.liveFolders.waitForFetches()
        #expect(fixture.manager.liveFolders.state(of: made.id)?.items.count == 2)

        // An empty source makes nothing.
        let empty = try #require(window.makeLiveFolderEditor(editing: nil, parentID: BrowserPinTree.rootID, index: nil))
        empty.onDone?("Nothing", "  ")
        #expect(fixture.manager.spaces.pinTree(inSpace: spaceID).liveFolders().count == 1)

        let edit = try #require(window.makeLiveFolderEditor(editing: made.id, parentID: nil, index: nil))
        #expect(edit.content.url == "o/r")
        edit.onDone?("Reviews", "review-requested:@me is:open")
        let edited = try #require(fixture.manager.spaces.pinTree(inSpace: spaceID).folder(id: made.id))
        #expect(edited.name == "Reviews")
        #expect(edited.source == .githubSearch(query: "review-requested:@me is:open"))
        // A plain folder never opens in the live folder editor.
        let plain = try #require(fixture.manager.spaces.addPinFolder(name: "Work", inSpace: spaceID))
        #expect(window.makeLiveFolderEditor(editing: plain.id, parentID: nil, index: nil) == nil)
    }
}
