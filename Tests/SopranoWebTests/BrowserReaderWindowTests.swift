@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// Reader and Translate through a real window manager (off-screen windows,
/// a temporary support folder, local fixture pages; a stand-in translator).
@MainActor
@Suite(.serialized)
struct BrowserReaderWindowTests {
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

        func page(_ html: String, _ name: String) throws -> URL {
            try ReaderFixtures.write(html, named: name, in: directory)
        }
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebReader-\(UUID().uuidString)", isDirectory: true)
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

    /// Loads `url` in a new tab of `window` and waits for its page-info
    /// report.
    private func open(_ url: URL, in window: BrowserWindowController) async throws -> BrowserTab {
        let tab = window.newTab(url: url.absoluteString)
        for _ in 0..<250 {
            if !tab.webView.isLoading, tab.webView.url?.lastPathComponent == url.lastPathComponent,
               tab.reader.isReaderable || tab.translation.language != nil
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The load event's second report.
        try await Task.sleep(for: .milliseconds(400))
        return tab
    }

    private func run(_ script: String, in tab: BrowserTab) async throws -> String {
        let value = try await tab.webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
        return value.map { "\($0)" } ?? ""
    }

    private func reader(_ words: [String], _ window: BrowserWindowController, _ tab: BrowserTab) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            window.performReaderCommand(words, tab: tab) { continuation.resume(returning: $0) }
        }
    }

    private func translate(_ window: BrowserWindowController, _ tab: BrowserTab, to target: String) async -> Result<Int, Error> {
        await withCheckedContinuation { continuation in
            window.translatePage(in: tab, to: target) { continuation.resume(returning: $0) }
        }
    }

    private func original(_ window: BrowserWindowController, _ tab: BrowserTab) async -> Result<Int, Error> {
        await withCheckedContinuation { continuation in
            window.showOriginal(in: tab) { continuation.resume(returning: $0) }
        }
    }

    /// ⇧⌘R by default, remappable, in the View menu.
    @Test func readerIsARegistryCommand() {
        let shortcut = BrowserShortcut("shift+cmd+r")!
        #expect(BrowserCommandID.reader.defaultShortcut == shortcut)
        #expect(BrowserCommandID.reader.isRemappable)
        #expect(BrowserCommandID.allCases.filter { $0.defaultShortcut == shortcut } == [.reader])
        #expect(!BrowserGlobalShortcut.systemChords.contains(shortcut))
        #expect(BrowserShortcut.reservedOwner(of: shortcut) == nil)
        #expect(BrowserCommandID.reader.command.menu == .view)
        #expect(BrowserCommandID.translatePage.command.menu == .view)
    }

    /// An article: the chip and ⇧⌘R show it in Reader in the same tab and
    /// put the page back without a reload; a page of links has neither.
    @Test func readerShowsTheArticleAndToggleBack() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let tab = try await open(fixture.page(ReaderFixtures.article, "article.html"), in: window)
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(tab.reader.isReaderable)
        #expect(BrowserCommandID.reader.command.state(context).isEnabled)
        #expect(BrowserCommandID.reader.command.state(context).title == "Show Reader")
        #expect(window.readerChip?.isHidden == false)
        let input = window.commandBarInput("/reader", mode: .actions, siteSearch: nil)
        #expect(BrowserCommandBarEngine.groups(for: input).flatMap(\.rows).first?.target == .command(.reader))
        _ = try await run("window.__marker = 5", in: tab)
        let backCount = tab.webView.backForwardList.backList.count

        let on = try await reader(["on"], window, tab).get()
        #expect(on.contains("reader: on"))
        #expect(on.contains("byline: By Mara Lind"))
        #expect(tab.reader.isActive)
        #expect(try await run("document.documentElement.className", in: tab) == "soprano-reader")
        #expect(try await run("String(document.querySelectorAll('.soprano-reader-content img').length)", in: tab) == "1")
        #expect(BrowserCommandID.reader.command.state(context).title == "Hide Reader")
        #expect(window.readerChip?.kind == .ink)

        // ⇧⌘R again: the page as it was, same document, same history.
        BrowserCommandID.reader.command.perform(in: context)
        for _ in 0..<100 where tab.reader.isActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!tab.reader.isActive)
        #expect(try await run("document.documentElement.className + '|' + window.__marker", in: tab) == "|5")
        #expect(tab.webView.backForwardList.backList.count == backCount)
        #expect(window.readerChip?.kind == .standard)

        // A page without an article: disabled, no chip, the CLI says so.
        let links = try await open(fixture.page(ReaderFixtures.short, "links.html"), in: window)
        #expect(window.selectedTab === links)
        #expect(!links.reader.isReaderable)
        #expect(!BrowserCommandID.reader.command.state(context).isEnabled)
        #expect(window.readerChip?.isHidden == true)
        let refused = await reader(["on"], window, links)
        #expect((try? refused.get()) == nil)
        if case let .failure(error) = refused {
            #expect(error.localizedDescription.contains("No article on this page."))
        }
        #expect(try await reader([], window, links).get().contains("article: no"))
    }

    /// Reader on, then a new page: the tab starts over.
    @Test func aNewPageLeavesTheReader() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let tab = try await open(fixture.page(ReaderFixtures.article, "article.html"), in: window)
        _ = try await reader(["on"], window, tab).get()
        #expect(tab.reader.isActive)
        let next = try fixture.page(ReaderFixtures.short, "links.html")
        tab.webView.load(URLRequest(url: next))
        for _ in 0..<250 where tab.webView.url?.lastPathComponent != "links.html" || tab.webView.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!tab.reader.isActive)
        #expect(tab.translation.phase == .original)
    }

    /// The page's language is detected; Translate changes its text nodes
    /// in batches and "Show Original" restores them; a missing pair names
    /// System Settings and leaves the page alone.
    @Test func translatesAndShowsTheOriginal() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        let service = FakeTranslationService()
        window.translationService = service
        let tab = try await open(fixture.page(ReaderFixtures.german, "hafen.html"), in: window)
        let context = BrowserCommandContext(manager: fixture.manager, controller: window)
        #expect(tab.translation.language == "de")
        #expect(BrowserCommandID.translatePage.command.state(context).isEnabled)
        let before = try await run("document.body.innerHTML", in: tab)

        let nodes = try await translate(window, tab, to: "en").get()
        #expect(nodes >= 5)
        #expect(service.pairs == ["de>en"])
        #expect(tab.translation.phase == .translated(target: "en", nodes: nodes))
        #expect(try await run("document.getElementById('second').textContent", in: tab).hasPrefix("[DAS CAFÉ AM KAI"))
        #expect(try await run("document.getElementById('keep').textContent", in: tab) == "Markenname Hafenblick")
        #expect(BrowserCommandID.translatePage.command.state(context).title == "Show Original")
        #expect(window.translateChip?.isHidden == false)
        #expect(window.translateChip?.title == "Translated")
        #expect(window.translateMenuItems(for: tab).first?.title == "Show Original")
        #expect(window.translateLines(for: tab).contains("translation: en (\(nodes) text nodes)"))

        _ = try await original(window, tab).get()
        #expect(tab.translation.phase == .original)
        #expect(try await run("document.body.innerHTML", in: tab) == before)

        // A pair not downloaded on this Mac.
        service.availability = .needsDownload
        let missing = await translate(window, tab, to: "fr")
        guard case let .failure(error) = missing else {
            Issue.record("translated without the languages")
            return
        }
        #expect(error as? BrowserTranslateError == .needsDownload(source: "de", target: "fr"))
        #expect(error.localizedDescription.contains("Translation Languages"))
        #expect(error.localizedDescription.contains("x-apple.systempreferences:com.apple.Localization-Settings.extension"))
        #expect(tab.translation.phase == .original)
        #expect(try await run("document.body.innerHTML", in: tab) == before)
        // Already in the language asked for.
        let same = await translate(window, tab, to: "de-CH")
        if case let .failure(error) = same {
            #expect(error as? BrowserTranslateError == .sameLanguage("de"))
        } else {
            Issue.record("translated into its own language")
        }
    }

    /// Translate and Reader together: the Reader shows the translation
    /// again, and leaving it brings back the translated original.
    @Test func readerKeepsTheTranslation() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let window = fixture.manager.newWindow()
        window.translationService = FakeTranslationService()
        let german = ReaderFixtures.german.replacingOccurrences(
            of: "<pre id=\"code\">", with: (1...8).map { "<p>Absatz \($0): Die Boote kehren am Abend in den Hafen zurück, beladen mit Fisch, und die Stadt erwacht noch einmal, bevor die Nacht über das Wasser fällt und die Lichter am Kai angehen.</p>" }.joined() + "<pre id=\"code\">"
        )
        let tab = try await open(fixture.page(german, "artikel.html"), in: window)
        #expect(tab.reader.isReaderable)
        _ = try await translate(window, tab, to: "en").get()
        _ = try await reader(["on"], window, tab).get()
        for _ in 0..<150 where !tab.translation.isTranslated {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.reader.isActive)
        #expect(tab.translation.isTranslated)
        let paragraphs = try await run(
            "Array.from(document.querySelectorAll('.soprano-reader-content p')).map((p) => p.textContent).join('\\n')", in: tab
        )
        #expect(paragraphs.contains("[ABSATZ 1:"))
        #expect(paragraphs.contains("[AM FRÜHEN MORGEN"))
    }

    /// A private window translates and keeps "Never Offer" to itself; a
    /// normal window saves it in Settings.
    @Test func privateWindowsTranslateAndSaveNothing() async throws {
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        let page = try fixture.page(ReaderFixtures.german, "hafen.html")
        let secret = fixture.manager.newPrivateWindow()
        secret.translationService = FakeTranslationService()
        let tab = try await open(page, in: secret)
        #expect(tab.translation.language == "de")
        #expect(try await translate(secret, tab, to: "en").get() > 0)
        secret.neverOfferTranslation(for: "de-DE")
        #expect(secret.neverTranslateLanguages == ["de"])
        #expect(fixture.manager.settingsStore.settings.neverTranslateLanguages.isEmpty)
        let saved = try? Data(contentsOf: fixture.directory.appendingPathComponent("settings.json"))
        #expect(saved.map { String(decoding: $0, as: UTF8.self).contains("\"de\"") } != true)

        let window = fixture.manager.newWindow()
        #expect(!window.neverTranslateLanguages.contains("de"))
        window.neverOfferTranslation(for: "de")
        #expect(fixture.manager.settingsStore.settings.neverTranslateLanguages == ["de"])
        #expect(window.translationOffer(for: tab) == nil)
    }
}
