@testable import SopranoWeb
import AppKit
import Testing

/// AppleScript's objects and `execute javascript` over a real window
/// manager (off-screen windows, a temporary support folder). The Apple
/// event glue runs in the harness (`--applescript`) and against the dev app.
@MainActor
@Suite(.serialized)
struct BrowserScriptingTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            BrowserScripting.manager = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebScripting-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let spaces = BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles.profiles,
            bookmarksURL: directory.appendingPathComponent("bookmarks.json")
        )
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
            defaults: UserDefaults(suiteName: "com.soprano.web.tests.\(UUID().uuidString)")!,
            filterLists: [],
            extensionStorage: .volatile,
            checksExtensionUpdates: false
        )
        BrowserScripting.manager = manager
        return Fixture(manager: manager, directory: directory)
    }

    private func execute(_ source: String?, in tab: BrowserScriptTab? = nil) async -> Result<String, BrowserScriptFailure> {
        await withCheckedContinuation { continuation in
            BrowserScripting.executeJavaScript(source, in: tab) { continuation.resume(returning: $0) }
        }
    }

    @Test func scriptsSeeNormalWindowsTheMostRecentFirstNeverPrivateOnes() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let first = fixture.manager.newWindow()
        let second = fixture.manager.newWindow(url: "https://example.com/")
        _ = fixture.manager.newPrivateWindow()
        fixture.manager.present(second)

        let windows = NSApplication.shared.scriptWindows
        #expect(windows.map(\.id) == [second.id, first.id])
        #expect(windows.map(\.scriptIndex) == [1, 2])
        #expect(windows[0].kind == "normal")
        #expect(windows[0].currentSpace?.scriptName == BrowserProfile.defaultName)
        #expect(NSApplication.shared.valueInScriptWindows(uniqueID: first.id.uuidString)?.id == first.id)
        #expect(NSApplication.shared.valueInScriptWindows(uniqueID: UUID().uuidString) == nil)
        #expect(NSApplication.shared.scriptSpaces.map(\.scriptIndex) == [1])
    }

    @Test func aTabReadsAndSetsItsAddressAndReadsAsGoneOnceClosed() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let added = window.newTab(url: "https://example.com/", select: false)
        let scriptWindow = BrowserScriptWindow(id: window.id)
        #expect(scriptWindow.tabs.map(\.tabID) == window.visibleTabs.map(\.id))
        let start = try #require(scriptWindow.activeTab)
        #expect(start.scriptURL == "about:start")
        #expect(start.selected)
        let tab = try #require(scriptWindow.valueInTabs(uniqueID: added.id.uuidString))
        #expect(tab.scriptIndex == 2)
        #expect(!tab.selected)

        // Setting the address goes through the address field's resolver.
        start.scriptURL = "example.org"
        #expect(window.visibleTabs[0].webView.url?.absoluteString == "https://example.org/")

        window.closeTab(id: added.id, archive: true)
        #expect(tab.tab == nil)
        #expect(tab.scriptURL.isEmpty)
        #expect(scriptWindow.valueInTabs(uniqueID: added.id.uuidString) == nil)
    }

    @Test func javaScriptRunsOnlyWhenAllowedAndAnswersAsJSON() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let tab = try #require(BrowserScriptWindow(id: window.id).activeTab)

        #expect(await execute("1 + 1", in: tab) == .failure(BrowserScriptFailure(
            number: Int(errAEEventNotPermitted), message: BrowserScripting.javaScriptDisabledMessage
        )))
        fixture.manager.settingsStore.update { $0.allowsJavaScriptFromAppleEvents = true }
        #expect(await execute("  ", in: tab).map { _ in "" } == .failure(BrowserScriptFailure(
            number: Int(errAEParamMissed), message: "Give the JavaScript to run."
        )))
        // Without a tab: the most recently active window's selected tab.
        // The answer is the CLI's `eval` JSON (indented).
        #expect(await execute("({ sum: 1 + 1 })") == .success("{\n  \"sum\": 2\n}"))
        #expect(await execute("await new Promise(r => setTimeout(() => r('a'), 50))", in: tab) == .success("\"a\""))
        guard case let .failure(thrown) = await execute("throw new Error('boom')", in: tab) else {
            Issue.record("a throw answered with a result")
            return
        }
        #expect(thrown.number == Int(errAEEventFailed))
        #expect(thrown.message.contains("boom"))

        window.closeTab(id: tab.tabID)
        #expect(await execute("1", in: tab) == .failure(BrowserScriptFailure(
            number: Int(errAENoSuchObject), message: "No tab to run it in."
        )))
    }
}
