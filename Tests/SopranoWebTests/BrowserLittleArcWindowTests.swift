@testable import SopranoWeb
import AppKit
import Testing

/// Little Arc windows through a real window manager (off-screen windows,
/// a temporary support folder, no network): ⌘O, "Open in", new tabs from
/// it, the idle pass and the session.
@MainActor
@Suite(.serialized)
struct BrowserLittleArcWindowTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL
        let work: BrowserSpace
        let home: BrowserSpace

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebLittleArc-\(UUID().uuidString)", isDirectory: true)
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
        let home = manager.spaces.defaultSpace!
        let work = manager.createSpace(name: "Work", icon: .none, color: .green)!
        return Fixture(manager: manager, directory: directory, work: work, home: home)
    }

    @Test func aLittleArcBelongsToTheMostRecentWindowsSpaceAndShowsNoSpaces() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let window = manager.newWindow(spaceID: fixture.work.id)
        let little = manager.newLittleArc()
        #expect(little.role == .little)
        #expect(little.littleSpaceID == fixture.work.id)
        #expect(!little.hasSpaces)
        #expect(little.dataContext === window.dataContext)
        #expect(little.tabs.count == 1)
        #expect(manager.windowMark(for: little).spaceName == fixture.work.displayName)
        // Its frame: the screen's top right.
        let frame = manager.sessionFrame(of: little)!
        let screen = manager.placement.screens()[0]
        #expect(frame.maxX == screen.maxX - BrowserLittleArcFrame.inset)
        #expect(frame.maxY == screen.maxY - BrowserLittleArcFrame.inset)
    }

    @Test func commandOMovesTheTabIntoAWindowShowingItsSpace() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let onHome = manager.newWindow(spaceID: fixture.home.id)
        let onWork = manager.newWindow(spaceID: fixture.work.id)
        let little = manager.newLittleArc(spaceID: fixture.work.id)
        manager.present(onHome)
        let tab = little.selectedTab!

        let target = manager.moveLittleArcToSpaceWindow(little)
        #expect(target === onWork)
        #expect(onWork.selectedTab === tab)
        #expect(tab.spaceID == fixture.work.id)
        #expect(!manager.controllers.contains { $0 === little })
        // The home window is untouched.
        #expect(onHome.currentSpaceID == fixture.home.id)
    }

    @Test func commandOSwitchesTheMostRecentWindowWhenNoneShowsTheSpace() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let window = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(spaceID: fixture.work.id)
        let tab = little.selectedTab!

        let target = manager.moveLittleArcToSpaceWindow(little)
        #expect(target === window)
        #expect(window.currentSpaceID == fixture.work.id)
        // No start tab was added for the Space: the moved tab is its only one.
        #expect(window.visibleTabs.map(\.id) == [tab.id])
        #expect(window.selectedTab === tab)
    }

    @Test func commandOOpensANewWindowWhenNoNormalWindowIsOpen() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let little = manager.newLittleArc(spaceID: fixture.work.id)
        let tab = little.selectedTab!
        let target = manager.moveLittleArcToSpaceWindow(little)
        #expect(target?.role == .normal)
        #expect(target?.currentSpaceID == fixture.work.id)
        #expect(target?.visibleTabs.map(\.id) == [tab.id])
        #expect(manager.controllers.count == 1)
    }

    @Test func openInMovesTheLittleArcToAnotherSpacesProfile() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        _ = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(spaceID: fixture.home.id)
        let items = little.openInMenu().items.filter { $0.state == .on }.map(\.title)
        #expect(items == [BrowserSpacesMenu.spaceTitle(fixture.home)])

        let moved = manager.moveLittleArc(little, toSpace: fixture.work.id)
        #expect(moved?.role == .little)
        #expect(moved?.littleSpaceID == fixture.work.id)
        #expect(moved?.dataContext === manager.context(for: fixture.work.profileID))
        #expect(moved?.tabs.count == 1)
        #expect(!manager.controllers.contains { $0 === little })
        // Its own Space again: nothing changes.
        #expect(moved.flatMap { manager.moveLittleArc($0, toSpace: fixture.work.id) } == nil)
    }

    @Test func newTabsFromALittleArcGoToItsSpacesWindow() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let onWork = manager.newWindow(spaceID: fixture.work.id)
        let onHome = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(spaceID: fixture.work.id)
        manager.present(onHome)
        let before = onWork.tabs.count
        // ⌘-click / target=_blank: a link tab after the Little Arc's page.
        let linked = little.insertLinkTab(little.makeTab(context: little.dataContext), opener: little.selectedTab!, select: false)
        #expect(onWork.tabs.contains { $0 === linked })
        #expect(onWork.tabs.count == before + 1)
        #expect(linked.spaceID == fixture.work.id)
        #expect(little.tabs.count == 1)
        #expect(!onHome.tabs.contains { $0 === linked })
    }

    @Test func duplicatingInALittleArcCopiesIntoItsSpacesWindow() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let onWork = manager.newWindow(spaceID: fixture.work.id)
        let onHome = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(url: "https://example.com/", spaceID: fixture.work.id)
        manager.present(onHome)
        let before = onWork.tabs.count
        // Vimium `yt`, an extension's tabs.duplicate, the harness.
        let copy = little.duplicateTab(id: little.selectedTab!.id)
        #expect(copy != nil)
        #expect(little.tabs.count == 1)
        #expect(onWork.tabs.count == before + 1)
        #expect(onWork.selectedTab === copy)
        #expect(copy?.dataContext === little.dataContext)
        #expect(copy?.spaceID == fixture.work.id)
        #expect(!onHome.tabs.contains { $0 === copy })
    }

    @Test func theIdlePassClosesALittleArcAfterSixHoursWithItsTabInTheArchive() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        let window = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(url: "https://example.com/idle", spaceID: fixture.work.id)
        let tab = try #require(little.selectedTab)
        let start = Date()
        tab.lifecycle.lastActiveAt = start
        let windowsBefore = manager.controllers.count

        // Five hours: still open; the selection does not reset its idle time.
        #expect(manager.archiveIdleTabs(now: start.addingTimeInterval(5 * 3600)).isEmpty)
        #expect(manager.controllers.contains { $0 === little })
        #expect(tab.lifecycle.lastActiveAt == start)

        let archived = manager.archiveIdleTabs(now: start.addingTimeInterval(6 * 3600 + 1))
        #expect(!manager.controllers.contains { $0 === little })
        #expect(manager.controllers.count == windowsBefore - 1)
        // No start tab took its place anywhere.
        #expect(window.tabs.count == 1)
        #expect(archived.map(\.url) == ["https://example.com/idle"])
        #expect(archived.map(\.spaceID) == [fixture.work.id])
        #expect(archived.map(\.profileID) == [fixture.work.profileID])
        // Not onto Recently Closed: it is in the Archive.
        #expect(manager.recentlyClosed.isEmpty)
    }

    @Test func aLittleArcIsSavedAndRestoredAsOne() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let manager = fixture.manager
        _ = manager.newWindow(spaceID: fixture.home.id)
        let little = manager.newLittleArc(url: "https://example.com/saved", spaceID: fixture.work.id)
        let session = manager.currentSession
        let saved = session.windows.first { $0.id == little.id }
        #expect(saved?.role == .little)
        #expect(saved?.currentSpaceID == fixture.work.id)
        #expect(saved?.tabs.count == 1)
        #expect(session.version == BrowserSession.currentVersion)
    }
}
