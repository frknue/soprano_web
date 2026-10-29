@testable import SopranoWeb
import AppKit
import Testing

/// The Site Control Center through a real window manager (off-screen
/// windows, a temporary support folder; pages are not loaded): the tab it
/// acts on and the profile store it writes.
@MainActor
@Suite(.serialized)
struct BrowserSiteControlWindowTests {
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
            .appendingPathComponent("SopranoWebSiteControl-\(UUID().uuidString)", isDirectory: true)
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

    @Test func thePopoverFollowsTheFocusedPane() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let first = try #require(window.selectedTab)
        let second = try #require(window.addSplitPane(url: "https://b.example/", commandBar: false))
        #expect(window.siteControlTab === second)
        #expect(window.siteControlState(for: second)?.host == "b.example")
        #expect(window.focusPane(number: 1))
        #expect(window.siteControlTab === first)
        let state = try #require(window.siteControlState(for: first))
        #expect(state.host == "a.example")
        #expect(state.tabID == first.id)
        #expect(state.dataTarget?.host == "a.example")
        // The view is built for that tab.
        let view = try #require(window.makeSiteControlView(for: first))
        #expect(view.state.host == "a.example")
        #expect(view.permissionButtons.count == 4)
        #expect(view.clearButton != nil)
    }

    @Test func thePopoverActsOnAnOpenPeek() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let opener = try #require(window.selectedTab)
        let peekTab = window.openPeek(URL(string: "https://peek.example/")!, from: opener)
        #expect(window.siteControlTab === peekTab)
        #expect(window.siteControlState(for: peekTab)?.host == "peek.example")
        window.setSitePermission(.camera, .allow, for: peekTab)
        // The Peek shares the opener's profile store.
        #expect(opener.dataContext.sitePermissions.decision(.camera, host: "peek.example") == .allow)
        #expect(window.siteControlState(for: peekTab)?.permissions.first?.choice == .allow)
        window.setSitePermission(.camera, .ask, for: peekTab)
        #expect(opener.dataContext.sitePermissions.decision(.camera, host: "peek.example") == nil)
    }

    @Test func aStartPageHasNoSiteControl() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let tab = try #require(window.selectedTab)
        #expect(window.siteControlState(for: tab) == nil)
        #expect(window.makeSiteControlView(for: tab) == nil)
    }

    @Test func aPrivateWindowWritesItsOverlayNotTheSavedStore() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let normal = fixture.manager.newWindow(url: "https://meet.example/")
        let saved = try #require(normal.selectedTab).dataContext.sitePermissions
        saved.set(.microphone, .allow, host: "meet.example")
        let window = fixture.manager.newPrivateWindow(url: "https://meet.example/")
        let tab = try #require(window.selectedTab)
        let state = try #require(window.siteControlState(for: tab))
        #expect(state.isPrivate)
        #expect(state.permissions.map(\.choice) == [.ask, .allow, .deny, .ask])
        window.setSitePermission(.camera, .deny, for: tab)
        #expect(tab.dataContext.sitePermissions.decision(.camera, host: "meet.example") == .deny)
        #expect(saved.decision(.camera, host: "meet.example") == nil)
    }

    @Test func theSiteCommandValidatesItsArguments() throws {
        func parse(_ words: [String]) throws -> BrowserCommandRequest? {
            try BrowserCommandRequest.parse(["soprano-web", "browser"] + words, environment: [:])
        }
        #expect(try parse(["site"])?.command == "site")
        #expect(try parse(["site", "clear"])?.arguments == ["clear"])
        #expect(try parse(["site", "permission", "camera", "deny"])?.arguments == ["permission", "camera", "deny"])
        #expect(throws: BrowserAutomationError.self) { try parse(["site", "permission", "zoom", "deny"]) }
        #expect(throws: BrowserAutomationError.self) { try parse(["site", "permission", "camera", "maybe"]) }
        #expect(throws: BrowserAutomationError.self) { try parse(["site", "wipe"]) }
    }
}
