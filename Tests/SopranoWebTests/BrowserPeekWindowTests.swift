@testable import SopranoWeb
import AppKit
import Testing

/// Peek through a real window manager (off-screen windows, a temporary
/// support folder; pages are not loaded): where it lives, what finds it,
/// Open as Tab, replacing, and what closes it.
@MainActor
@Suite(.serialized)
struct BrowserPeekWindowTests {
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
            .appendingPathComponent("SopranoWebPeek-\(UUID().uuidString)", isDirectory: true)
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

    private let link = URL(string: "https://other.example/")!

    private func escape(in window: BrowserWindowController) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.window?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
    }

    @Test func aPeekIsOverThePageInTheOpenersContextAndOutsideTheTabList() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let tabCount = window.tabs.count

        let peekTab = window.openPeek(link, from: opener)
        #expect(window.peek?.tab === peekTab)
        #expect(window.peek?.openerID == opener.id)
        #expect(peekTab.dataContext === opener.dataContext)
        #expect(window.tabs.count == tabCount)
        #expect(!window.tabs.contains { $0 === peekTab })
        #expect(window.selectedTab === opener)
        // Every WebKit callback finds it by its web view.
        #expect(window.tab(for: peekTab.webView) === peekTab)
        #expect(fixture.manager.tab(forWebView: peekTab.webView) === peekTab)
        #expect(fixture.manager.tabOrPeek(id: peekTab.id)?.tab === peekTab)
        #expect(fixture.manager.tab(id: peekTab.id) == nil)
        #expect(peekTab.webView.navigationDelegate === window)
        #expect(peekTab.webView.uiDelegate === window)
        #expect(peekTab.webView.isDescendant(of: window.webArea))
        #expect(window.peek!.view.superview === window.webArea)
        // Page commands and link tabs follow the page shown.
        #expect(window.pageTab === peekTab)
        #expect(window.linkOpener(peekTab) === opener)
        #expect(window.tabsWithPeek.last === peekTab)
        // It is never saved.
        #expect(window.windowState.tabs.count == tabCount)
    }

    @Test func aSecondPeekReplacesTheFirst() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let first = window.openPeek(link, from: opener)
        let firstView = window.peek!.view
        // From inside the Peek too (⇧-click on its page): over the same tab.
        let second = window.openPeek(URL(string: "https://third.example/")!, from: first)
        #expect(window.peek?.tab === second)
        #expect(window.peek?.openerID == opener.id)
        #expect(firstView.superview == nil)
        #expect(first.webView.superview == nil)
        #expect(first.webView.navigationDelegate == nil)
        #expect(window.tab(for: first.webView) == nil)
        #expect(window.webArea.subviews.filter { $0 is BrowserPeekView }.count == 1)
    }

    @Test func openAsTabPutsTheSameWebViewAfterTheOpener() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let after = window.newTab(url: "https://after.example/", select: false)
        window.selectTab(id: opener.id, focus: false)
        let peekTab = window.openPeek(link, from: opener)
        let webView = peekTab.webView

        // ⌘O runs the registry command (the Little Arc's ⌘O otherwise).
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(BrowserCommandID.openInSpaceWindow.command.state(context).isEnabled)
        #expect(BrowserCommandID.openInSpaceWindow.command.state(context).title == "Open Peek as Tab")
        BrowserCommandID.openInSpaceWindow.command.perform(in: context)

        #expect(window.peek == nil)
        #expect(window.visibleTabs.map(\.id) == [opener.id, peekTab.id, after.id])
        #expect(window.selectedTab === peekTab)
        // The page and its back/forward list come along: the same web view.
        #expect(peekTab.webView === webView)
        #expect(webView.isDescendant(of: window.webArea))
        #expect(!webView.isHidden)
        #expect(peekTab.origin == .today)
        #expect(peekTab.links.openerID == opener.id)
        #expect(peekTab.spaceID == opener.spaceID)
        #expect(window.tab(for: webView) === peekTab)
        #expect(window.windowState.tabs.count == 3)
        // Without a Peek, ⌘O is off in a normal window.
        #expect(!BrowserCommandID.openInSpaceWindow.command.state(context).isEnabled)
    }

    @Test func openAsTabFromAPinnedTabLandsAsATodayTab() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let spaceID = window.currentSpaceID!
        let pin = fixture.manager.spaces.addPin(url: "https://pinned.example/", title: "Pinned", inSpace: spaceID)!
        window.openPin(pin.id)
        let opener = window.selectedTab!
        #expect(opener.origin == .pinned(pin.id))
        let peekTab = window.openPeek(link, from: opener)
        #expect(window.openPeekAsTab() === peekTab)
        #expect(peekTab.origin == .today)
        #expect(window.tabs.contains { $0 === peekTab })
        #expect(window.selectedTab === peekTab)
        #expect(opener.origin == .pinned(pin.id))
        #expect(window.visibleTabs.contains { $0 === opener })
    }

    @Test func escapeInThePeekClosesIt() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        // Esc in the Peek's page (its key handler, before Vimium).
        let peekTab = window.openPeek(link, from: opener)
        #expect(peekTab.webView.keyHandler?(escape(in: window)) == true)
        #expect(window.peek == nil)
        #expect(peekTab.webView.superview == nil)
        // Esc in a tab's page goes to Vimium as before.
        #expect(!window.closesPeek(on: escape(in: window), in: opener))
    }

    @Test func commandWClosesThePeekNotTheTab() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let tabCount = window.tabs.count
        window.openPeek(link, from: opener)
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(BrowserCommandID.closeTab.command.state(context).title == "Close Peek")
        BrowserCommandID.closeTab.command.perform(in: context)
        #expect(window.peek == nil)
        #expect(window.tabs.count == tabCount)
        #expect(window.selectedTab === opener)
    }

    @Test func theCloseButtonAndTheDimmedPageCloseIt() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let tabCount = window.tabs.count
        window.openPeek(link, from: opener)
        // The button's action as a click sends it (`performClick` spins a
        // nested run loop, which the test runner must not see).
        let button = window.peek!.view.closeButton
        NSApp.sendAction(button.action!, to: button.target, from: button)
        #expect(window.peek == nil)
        window.openPeek(link, from: opener)
        window.peek!.view.backdrop.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!)
        #expect(window.peek == nil)
        #expect(window.tabs.count == tabCount)
    }

    @Test func leavingTheOpenerClosesThePeek() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let opener = window.selectedTab!
        let other = window.newTab(url: "https://after.example/", select: false)

        window.openPeek(link, from: opener)
        window.selectTab(id: other.id, focus: false)
        #expect(window.peek == nil)

        window.openPeek(link, from: other)
        window.closeTab(id: other.id)
        #expect(window.peek == nil)
    }

    @Test func aPrivateWindowsPeekUsesItsContext() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newPrivateWindow()
        let opener = window.selectedTab!
        let peekTab = window.openPeek(link, from: opener)
        #expect(peekTab.dataContext === window.dataContext)
        #expect(peekTab.dataContext.kind.isPrivate)
        #expect(!peekTab.dataContext.kind.recordsHistory)
        #expect(peekTab.webView.configuration.websiteDataStore === opener.webView.configuration.websiteDataStore)
    }

    @Test func theCLIOpensReportsAndClosesAPeek() {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        func run(_ arguments: [String]) -> Result<String, Error> {
            BrowserAutomationRouter.peek(BrowserCommandRequest(command: "peek", arguments: arguments, tabIndex: nil), in: window)
        }
        #expect((try? run([]).get()) == "no peek")
        #expect((try? run(["https://other.example/"]).get()) == "peek https://other.example/ over tab 1")
        #expect(window.peek != nil)
        #expect((try? run(["close"]).get()) == "closed peek")
        #expect(window.peek == nil)
        #expect((try? run(["close"]).get()) == nil)
        #expect(throws: BrowserAutomationError.self) {
            try BrowserCommandRequest.parse(["SopranoWeb", "browser", "peek", "a", "b"])
        }
    }
}
