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

    // MARK: P6 review regressions

    /// P2-1: the harness's Connection press keeps the popover view (the
    /// button's target) alive, so the details sheet opens.
    @Test func theHarnessConnectionPressOpensTheSheet() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let hostWindow = try #require(window.window)
        SnapshotCommand.openConnectionDetails(controller: window)
        let sheet = try #require(hostWindow.attachedSheet)
        hostWindow.endSheet(sheet)
    }

    /// P3-1: the open popover closes when its tab stops being the page,
    /// and its actions act on its own tab's current site.
    @Test func thePopoverFollowsItsTab() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let first = try #require(window.selectedTab)
        let hostWindow = try #require(window.window)
        let view = try #require(window.makeSiteControlView(for: first))
        window.siteControlPanel.show(view, below: window.toolbar.securityAnchor, in: hostWindow)
        #expect(window.siteControlPanel.isShown)
        window.updateSiteControlPanel()
        #expect(window.siteControlPanel.isShown)

        window.newTab(url: "https://b.example/", select: true)
        window.updateChrome()
        #expect(!window.siteControlPanel.isShown)

        // Zoom acts on the popover's tab though it is no longer the page.
        let before = first.zoom
        view.onZoom?(.zoomIn)
        #expect(first.zoom > before)

        // The tab went to another site: the switch writes that site.
        window.navigate(first, to: URL(string: "https://c.example/")!)
        #expect(window.siteControlHost(of: first) == "c.example")
        view.onBlocksAds?(false)
        #expect(first.dataContext.sitePermissions.blocksContent(host: "c.example") == false)
        #expect(first.dataContext.sitePermissions.blocksContent(host: "a.example") == true)
    }

    /// P3-2: on a certificate interstitial (an `about:blank` page) a
    /// permission choice is stored under the interstitial's host.
    @Test func anInterstitialStoresPermissionsForItsHost() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let tab = try #require(window.selectedTab)
        tab.certificateInterstitial = BrowserCertificateInterstitial(
            token: "t",
            host: "Bad.example",
            failedURL: URL(string: "https://bad.example/")!,
            problem: .selfSigned,
            trust: nil
        )
        #expect(window.siteControlState(for: tab)?.host == "bad.example")
        window.setSitePermission(.camera, .allow, for: tab)
        #expect(tab.dataContext.sitePermissions.decision(.camera, host: "bad.example") == .allow)
    }

    /// P3-3: unchecking "Allow on <host>" removes a parent site that
    /// grants it, not only an exact entry.
    @Test func uncheckingAllowHereRemovesCoveringParentSites() {
        let covering = BrowserSiteControlState.ExtensionAccess.coveringSites(
            host: "sub.example.com",
            allowedSites: ["example.com", "sub.example.com", "other.com", "deep.sub.example.com"]
        )
        #expect(covering == ["example.com", "sub.example.com"])
        let remaining = ["example.com", "other.com"].filter { !covering.contains($0) }
        #expect(!BrowserSiteControlState.ExtensionAccess.isAllowed(
            host: "sub.example.com",
            access: .specificSites,
            allowedSites: remaining
        ))
    }

    // MARK: Boosts

    /// Every tab (the Peek's and private windows' too) gets the enabled
    /// Boosts' scripts in the Boost world, swapped on every change.
    @Test func boostScriptsFollowTheStore() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://www.a.example/")
        let tab = try #require(window.selectedTab)
        let privateTab = try #require(fixture.manager.newPrivateWindow(url: "https://a.example/").selectedTab)
        func boostScripts(_ tab: BrowserTab) -> [String] {
            tab.webView.configuration.userContentController.userScripts
                .map(\.source)
                .filter { $0.hasPrefix(BrowserBoostScripts.marker) }
        }
        let others = tab.webView.configuration.userContentController.userScripts.count
        #expect(boostScripts(tab).isEmpty)
        #expect(window.siteControlState(for: tab)?.boost == .init(host: "a.example", boost: nil))

        fixture.manager.boosts.update(host: "a.example") {
            $0.css = "body { color: red }"
            $0.js = "document.title = 'boosted'"
        }
        #expect(boostScripts(tab).count == 2)
        #expect(boostScripts(privateTab).count == 2)
        #expect(boostScripts(tab).contains { $0.contains("document.title = 'boosted'") })
        #expect(tab.webView.configuration.userContentController.userScripts.count == others + 2)
        #expect(window.siteControlState(for: tab)?.boost?.title == "On")

        fixture.manager.boosts.update(host: "a.example") { $0.isEnabled = false }
        #expect(boostScripts(tab).isEmpty)
        #expect(window.siteControlState(for: tab)?.boost?.title == "Off")
        #expect(tab.webView.configuration.userContentController.userScripts.count == others)
    }

    /// `/boost` and the Site Control Center's row open the editor for the
    /// page's site; Save writes the store.
    @Test func theBoostEditorSavesTheSitesBoost() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://www.a.example/page")
        let hostWindow = try #require(window.window)
        #expect(BrowserCommandID.editBoost.command.state(BrowserCommandContext(manager: fixture.manager, controller: window)).isEnabled)
        BrowserCommandID.editBoost.command.perform(in: BrowserCommandContext(manager: fixture.manager, controller: window))
        let editor = try #require(window.boostEditor)
        #expect(editor.host == "a.example")
        #expect(hostWindow.attachedSheet === editor.window)
        editor.cssView.string = "p { margin: 0 }"
        editor.zapView.string = "#ad\n\n .banner \n"
        editor.save()
        let boost = try #require(fixture.manager.boosts.boost(host: "www.a.example"))
        #expect(boost.css == "p { margin: 0 }")
        #expect(boost.zaps == ["#ad", ".banner"])
        #expect(boost.isEnabled)
    }

    /// A zap pick from the isolated world adds the built selector.
    @Test func aZapPickAddsItsSelector() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let tab = try #require(window.selectedTab)
        window.navigate(tab, to: URL(string: "https://a.example/")!)
        window.zapSession = (tab.id, "a.example")
        let body: [String: Any] = ["path": [
            ["tag": "div", "id": "", "classes": ["promo"], "index": 2, "count": 3],
            ["tag": "main", "id": "content", "classes": [], "index": 1, "count": 1],
        ]]
        window.recordZap(body, tab: tab)
        #expect(fixture.manager.boosts.boost(host: "a.example")?.zaps == ["#content > div.promo:nth-of-type(2)"])
        // Not in Zap mode: ignored.
        window.zapSession = nil
        window.recordZap(["path": [["tag": "p", "index": 1, "count": 1]]], tab: tab)
        #expect(fixture.manager.boosts.boost(host: "a.example")?.zaps.count == 1)
    }

    private func escape(in window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
    }

    /// P7 review P3-1: Zap mode ends with its document and its page; a
    /// pick from another site than the session's records nothing.
    @Test func zapModeEndsWithItsPage() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let tab = try #require(window.selectedTab)
        window.navigate(tab, to: URL(string: "https://a.example/")!)
        let pick: [String: Any] = ["path": [["tag": "p", "id": "ad", "classes": [], "index": 1, "count": 1]]]

        // A new document in the tab: Esc is the page's again.
        window.zapSession = (tab.id, "a.example")
        window.webView(tab.webView, didCommit: nil)
        #expect(window.zapSession == nil)
        #expect(!window.endsZap(on: escape(in: window.window), in: tab))

        // The session's host decides, not the tab's current page.
        window.zapSession = (tab.id, "b.example")
        window.recordZap(pick, tab: tab)
        #expect(fixture.manager.boosts.boost(host: "a.example") == nil)
        #expect(fixture.manager.boosts.boost(host: "b.example") == nil)

        // Another tab selected: Zap mode stops.
        window.zapSession = (tab.id, "a.example")
        window.newTab(url: "https://c.example/", select: true)
        window.updateChrome()
        #expect(window.zapSession == nil)
    }

    /// P7 review P3-5: a store change that leaves the editor's zaps alone
    /// keeps the user's unsaved zap list; a change to them replaces it.
    /// P3-6: the open popover's Boost row follows the store.
    @Test func boostChangesKeepUnsavedEditsAndRefreshThePopover() throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow(url: "https://a.example/")
        let tab = try #require(window.selectedTab)
        let hostWindow = try #require(window.window)
        let view = try #require(window.makeSiteControlView(for: tab))
        window.siteControlPanel.show(view, below: window.toolbar.securityAnchor, in: hostWindow)
        #expect(window.siteControlPanel.content?.state.boost?.exists == false)
        fixture.manager.boosts.update(host: "a.example") { $0.css = "p {}" }
        #expect(window.siteControlPanel.content?.state.boost?.title == "On")
        window.siteControlPanel.close()

        window.showBoostEditor()
        let editor = try #require(window.boostEditor)
        editor.zapView.string = "#mine"
        fixture.manager.boosts.update(host: "other.example") { $0.css = "b {}" }
        fixture.manager.boosts.update(host: "a.example") { $0.css = "p { margin: 0 }" }
        #expect(editor.zapView.string == "#mine")
        fixture.manager.boosts.zap("#ad", host: "a.example")
        #expect(editor.zapView.string == "#ad")
        hostWindow.endSheet(editor.window)
    }

    /// P7 review P2-3: Return in the editor's code views is a newline;
    /// Save is ⌘↩.
    @Test func returnInTheBoostEditorIsANewline() throws {
        var saved = false
        let editor = BrowserBoostEditor(boost: BrowserBoost(host: "a.example"), theme: .folioPaper)
        editor.onSave = { _ in saved = true }
        editor.window.makeFirstResponder(editor.cssView)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        #expect(!editor.window.performKeyEquivalent(with: event))
        #expect(!saved)
        var queue = editor.window.contentView.map { [$0] } ?? []
        var saveButton: NSButton?
        while let view = queue.popLast() {
            if let button = view as? NSButton, button.title == "Save" { saveButton = button }
            queue += view.subviews
        }
        #expect(saveButton?.keyEquivalent == "\r")
        #expect(saveButton?.keyEquivalentModifierMask == .command)
    }
}
