@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// The Mini Player through a real window manager (off-screen windows and
/// panel, a temporary support folder). Media reports are fed as the page
/// script would post them; one test loads real pages for the round trip.
@MainActor
@Suite(.serialized)
struct BrowserMiniPlayerWindowTests {
    @MainActor
    private struct Fixture {
        let manager: BrowserWindowManager
        let directory: URL

        func tearDown() {
            for controller in manager.controllers {
                manager.closeWindow(controller, remember: false)
            }
            manager.miniPlayer.panel?.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebMiniPlayer-\(UUID().uuidString)", isDirectory: true)
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
        return Fixture(manager: manager, directory: directory)
    }

    /// What the page script reports for a main frame that plays.
    private func play(_ tab: BrowserTab, in window: BrowserWindowController, video: Bool = true, title: String = "Clip") {
        var report = BrowserMediaReport(frame: "main-\(tab.id.uuidString.prefix(8))")
        report.isPlaying = true
        report.hasVisibleVideo = video
        report.hasMedia = true
        report.title = title
        report.artist = "Artist"
        tab.media.info.update(report, isMainFrame: true)
        tab.media.changedAt = Date()
        window.mediaChanged(tab)
    }

    @Test func leavingAPlayingVideoMovesItsWebViewAndComingBackReturnsIt() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let video = try #require(window.selectedTab)
        let other = window.newTab(url: "https://b.example/")
        window.selectTab(id: video.id, focus: false)
        play(video, in: window)
        let webView = video.webView
        let player = fixture.manager.miniPlayer

        window.selectTab(id: other.id, focus: false)
        #expect(player.hosts(video))
        #expect(player.controller === window)
        #expect(webView.window === player.panel)
        #expect(!webView.isHidden)
        // Still the tab's own, bound web view.
        #expect(video.webView === webView)
        #expect(webView.navigationDelegate === window && webView.uiDelegate === window)
        #expect(window.tabs.contains { $0 === video })
        // It never sleeps or archives; layout passes leave it in the panel.
        #expect(window.sleepExemption(video) == .miniPlayer)
        #expect(window.archiveExemption(video) == .miniPlayer)
        window.sleepTab(video)
        #expect(!video.isAsleep && video.webView === webView)
        window.applyPaneLayout()
        #expect(webView.window === player.panel && !webView.isHidden)
        // The rail shows it, marked as in the Mini Player.
        let item = try #require(window.verticalTabsView.mediaControls.item)
        #expect(item.tabID == video.id && item.inMiniPlayer && item.title == "Clip" && item.subtitle == "Artist")
        #expect(window.toolbar.mediaControls.item == nil)

        window.selectTab(id: video.id, focus: false)
        #expect(!player.isOpen)
        #expect(webView.superview === window.webArea)
        #expect(!webView.isHidden)
        #expect(window.sleepExemption(video) == .selected)
        #expect(window.verticalTabsView.mediaControls.isHidden)
    }

    @Test func audioAloneShowsTheControlsWithoutAPanel() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://music.example/")
        let music = try #require(window.selectedTab)
        play(music, in: window, video: false, title: "Song")
        // On screen: no controls for it.
        #expect(window.mediaControlTab == nil)
        let other = window.newTab(url: "https://b.example/")
        #expect(window.selectedTab === other)
        #expect(!fixture.manager.miniPlayer.isOpen)
        #expect(window.mediaControlTab === music)
        #expect(window.verticalTabsView.mediaControls.item?.title == "Song")
        // The rail's mute and click act on it.
        window.verticalTabsView.mediaControls.mutePressed()
        #expect(music.isMuted)
        #expect(window.verticalTabsView.mediaControls.item?.isMuted == true)
        window.verticalTabsView.mediaControls.onSelect?(music.id)
        #expect(window.selectedTab === music)
        // Without a rail the toolbar shows them.
        window.selectTab(id: other.id, focus: false)
        window.toggleVerticalSidebar()
        #expect(window.verticalTabsView.isHidden)
        #expect(window.toolbar.mediaControls.item?.tabID == music.id)
        #expect(!window.toolbar.mediaControls.isHidden)
    }

    @Test func theSettingPanesAPeekAndAPopupKeepTheVideoInPlace() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let player = fixture.manager.miniPlayer
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let first = try #require(window.selectedTab)

        // Settings ▸ Mini Player off.
        fixture.manager.settingsStore.update { $0.miniPlayer = false }
        play(first, in: window)
        let other = window.newTab(url: "https://b.example/")
        #expect(!player.isOpen)
        #expect(first.webView.isHidden)
        fixture.manager.settingsStore.update { $0.miniPlayer = true }

        // A pane that stays on screen never moves.
        window.selectTab(id: first.id, focus: false)
        let pane = try #require(window.addSplitPane(url: "https://c.example/", commandBar: false))
        #expect(window.selectedTab === pane)
        window.selectTab(id: first.id, focus: false)
        window.selectTab(id: pane.id, focus: false)
        #expect(!player.isOpen)
        #expect(window.miniPlayerDecision(first, shown: window.shownTabs) == .visible)

        // A Peek's video doesn't trigger (the pane's video stopped first).
        window.resetMediaInfo(first)
        window.selectTab(id: other.id, focus: false)
        let peekTab = window.openPeek(URL(string: "https://peek.example/")!, from: other)
        play(peekTab, in: window)
        #expect(window.miniPlayerDecision(peekTab, shown: []) == .peek)
        window.closePeek()
        #expect(!player.isOpen)

        // A pop-up window's tab never.
        #expect(BrowserMiniPlayerRule.decide(BrowserMiniPlayerCandidate(hasVisibleVideo: true, isPlaying: true, isPopup: true)) == .popup)
    }

    @Test func aSpaceSwitchMovesTheVideoAndLeavesThePanelAlone() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let player = fixture.manager.miniPlayer
        let work = try #require(fixture.manager.createSpace(name: "Work", icon: .none, color: .green))
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let home = try #require(window.currentSpaceID)
        let video = try #require(window.selectedTab)
        play(video, in: window)

        // An empty Space: `leavePage` hides the page, not the panel's.
        window.switchToSpace(work.id, focus: false)
        #expect(player.hosts(video))
        #expect(!video.webView.isHidden && video.webView.window === player.panel)
        // The rail's controls show it from the other Space.
        #expect(window.mediaControlTab === video)

        // Back: the remembered selection is the video's tab.
        window.switchToSpace(home, focus: false)
        #expect(!player.isOpen)
        #expect(window.selectedTab === video && !video.webView.isHidden)

        // A Space with tabs: through the selection.
        window.switchToSpace(work.id, focus: false)
        #expect(player.hosts(video))
        #expect(!video.webView.isHidden)
        // Selecting the tab from the controls switches back.
        window.verticalTabsView.mediaControls.onSelect?(video.id)
        #expect(window.currentSpaceID == home)
        #expect(!player.isOpen && window.selectedTab === video)
    }

    @Test func oneMiniPlayerAtATimeAndItsButtons() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let player = fixture.manager.miniPlayer
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let first = try #require(window.selectedTab)
        play(first, in: window)
        let second = window.newTab(url: "https://b.example/")
        #expect(player.hosts(first))
        play(second, in: window)
        let third = window.newTab(url: "https://c.example/")
        // The second replaces the first, which goes back hidden.
        #expect(player.hosts(second))
        #expect(first.webView.superview === window.webArea && first.webView.isHidden)

        // Close: pauses and puts the page back, hidden; nothing selected.
        player.panel?.playerView.closePressed()
        #expect(!player.isOpen)
        #expect(second.webView.superview === window.webArea && second.webView.isHidden)
        #expect(window.selectedTab === third)

        // Back to Tab selects it.
        window.selectTab(id: second.id, focus: false)
        window.selectTab(id: third.id, focus: false)
        #expect(player.hosts(second))
        player.panel?.playerView.returnPressed()
        #expect(!player.isOpen)
        #expect(window.selectedTab === second && !second.webView.isHidden)

        // Closing the tab while it plays in the panel.
        window.selectTab(id: third.id, focus: false)
        #expect(player.hosts(second))
        window.closeTab(id: second.id)
        #expect(!player.isOpen)
        #expect(player.panel?.playerView.host.subviews.isEmpty == true)
    }

    @Test func thePanelRemembersWhereTheUserLeftItNeverFromAPrivateWindow() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let player = fixture.manager.miniPlayer
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let video = try #require(window.selectedTab)
        play(video, in: window)
        window.newTab(url: "https://b.example/")
        let panel = try #require(player.panel)
        // Placed by code: nothing remembered yet.
        #expect(player.rememberedFrame == nil)
        let windowFrame = try #require(window.window?.frame)
        #expect(windowFrame.contains(panel.frame))
        let moved = NSRect(x: windowFrame.minX + 40, y: windowFrame.minY + 60, width: 480, height: 270)
        panel.setFrame(moved, display: false)
        player.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        #expect(player.rememberedFrame == moved)
        // It opens there next time.
        window.selectTab(id: video.id, focus: false)
        window.selectTab(index: 1, focus: false)
        #expect(player.hosts(video) && panel.frame == moved)
        window.selectTab(id: video.id, focus: false)

        // A private window may open one (leaving the tab was the user's
        // doing) but saves nothing.
        let secret = fixture.manager.newPrivateWindow(url: "https://private.example/")
        let privateVideo = try #require(secret.selectedTab)
        play(privateVideo, in: secret)
        secret.newTab(url: "https://other.example/")
        #expect(player.hosts(privateVideo) && player.controller === secret)
        #expect(!player.persistsFrame)
        panel.setFrame(moved.offsetBy(dx: 10, dy: 10), display: false)
        player.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        #expect(player.rememberedFrame == moved)
        // Closing the private window takes its page out of the panel.
        fixture.manager.closeWindow(secret, remember: false)
        #expect(!player.isOpen)
    }

    @Test func theRoundTripKeepsThePageItsHistoryAndItsHandlers() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let player = fixture.manager.miniPlayer
        let window = fixture.manager.newWindow()
        let page = fixture.directory.appendingPathComponent("page.html")
        try Data("<!doctype html><title>page</title><video></video>".utf8).write(to: page)
        let tab = window.newTab(url: page.absoluteString)
        let webView = tab.webView
        for _ in 0..<250 {
            if !webView.isLoading, webView.url?.lastPathComponent == "page.html" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(webView.url?.lastPathComponent == "page.html")
        // Two entries in the same document (a reload would lose the marker).
        _ = try await webView.evaluateJavaScript(
            "history.pushState({}, '', '?two'); history.pushState({}, '', '?three'); window.__marker = 42",
            in: nil,
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(100))
        let backCount = webView.backForwardList.backList.count
        #expect(backCount == 2)
        // The page's own (idle) report lands before the fed one.
        try await Task.sleep(for: .milliseconds(500))
        play(tab, in: window)
        let other = window.newTab()
        #expect(player.hosts(tab))
        window.selectTab(id: tab.id, focus: false)
        #expect(!player.isOpen)
        window.selectTab(id: other.id, focus: false)
        window.selectTab(id: tab.id, focus: false)

        // Same web view, same document (no reload), same history.
        #expect(tab.webView === webView)
        #expect(webView.backForwardList.backList.count == backCount)
        let marker = try await webView.evaluateJavaScript("window.__marker", in: nil, contentWorld: .page) as? Int
        #expect(marker == 42)
        // The page script and its message handler are still there.
        let handler = try await webView.evaluateJavaScript(
            "typeof globalThis.__sopranoMediaControl + ' ' + typeof window.webkit.messageHandlers.sopranoWeb",
            in: nil,
            contentWorld: BrowserPageScripts.isolatedWorld
        ) as? String
        #expect(handler == "function object")
        // The fill style came off with the return.
        let fill = try await webView.evaluateJavaScript(
            BrowserMediaScripts.fillStateSource, in: nil, contentWorld: BrowserPageScripts.isolatedWorld
        ) as? String
        #expect(fill == "")
    }

    @Test func theCLIReportsTheTabTheControlsShow() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        var outcome: Result<String, Error>?
        window.performMediaCommand(["info"], tab: nil) { outcome = $0 }
        #expect(throws: BrowserAutomationError.self) { try outcome?.get() }

        let video = try #require(window.selectedTab)
        play(video, in: window, title: "Trailer")
        // On screen and playing: the selected tab answers.
        window.performMediaCommand([], tab: nil) { outcome = $0 }
        #expect(try outcome?.get().contains("state: playing") == true)
        window.newTab(url: "https://b.example/")
        window.performMediaCommand(["info"], tab: nil) { outcome = $0 }
        let lines = try #require(try outcome?.get())
        #expect(lines.hasPrefix("tab 1: "))
        #expect(lines.contains("video: visible"))
        #expect(lines.contains("session: Trailer — Artist"))
        #expect(lines.contains("mini-player: open 400x225"))
        #expect(lines.contains("awake: miniPlayer"))
        window.performMediaCommand(["mute"], tab: nil) { outcome = $0 }
        #expect(try outcome?.get() == "muted")
        #expect(video.isMuted)
    }
}
