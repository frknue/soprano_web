@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSessionRestoreTests {
    private let history = Data("archived back/forward list".utf8)

    private func temporaryStore() -> (BrowserSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebRestore-\(UUID().uuidString)", isDirectory: true)
        return (BrowserSessionStore(url: directory.appendingPathComponent("session.json")), directory)
    }

    private func write(_ json: String, to store: BrowserSessionStore, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
    }

    @Test func versionTwoRoundTripsWindowsFramesSelectionAndClosedEntries() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 40, y: 60, width: 1280, height: 800)),
            tabs: [
                BrowserTabState(url: "https://example.com/b", title: "B", zoom: 1.1, interactionState: history),
                BrowserTabState(url: nil, title: "New Tab", zoom: 1),
            ],
            selectedIndex: 1
        )
        let second = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 900, y: 20, width: 900, height: 700)),
            tabs: [BrowserTabState(url: "https://webkit.org", title: "WebKit")],
            selectedIndex: 0
        )
        let closedWindow = BrowserWindowState(
            frame: BrowserWindowFrame(NSRect(x: 10, y: 10, width: 800, height: 600)),
            tabs: [
                BrowserTabState(url: "https://example.com/x", title: "X", interactionState: history),
                BrowserTabState(url: "https://example.com/y", title: "Y"),
            ],
            selectedIndex: 1
        )
        let session = BrowserSession(
            windows: [first, second],
            activeWindowIndex: 1,
            recentlyClosed: [
                BrowserClosedEntry(.tab(BrowserTabState(url: "https://example.com/c", title: "C"), windowID: first.id, index: 2)),
                BrowserClosedEntry(.window(closedWindow)),
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(session)

        let loaded = store.load()
        #expect(loaded == session)
        #expect(loaded?.version == 2)
        #expect(loaded?.windows.map(\.frame?.rect) == [
            NSRect(x: 40, y: 60, width: 1280, height: 800),
            NSRect(x: 900, y: 20, width: 900, height: 700),
        ])
        #expect(loaded?.windows.first?.selectedIndex == 1)
        #expect(loaded?.windows.first?.tabs.first?.interactionState == history)
        #expect(loaded?.recentlyClosed.last?.content == .window(closedWindow))
        // A version 2 file is not a migration.
        #expect(!FileManager.default.fileExists(atPath: store.migratedURL.path))
    }

    @Test func windowsKeepTheirProfileAndADeletedOneFallsBackToDefault() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var profiles = BrowserProfileList()
        let work = profiles.add(name: "Work")
        let gone = profiles.add(name: "Gone")
        let workWindow = BrowserWindowState(tabs: [BrowserTabState(url: "https://work.example", title: "W")], profileID: work.id)
        let goneWindow = BrowserWindowState(tabs: [BrowserTabState(url: "https://gone.example", title: "G")], profileID: gone.id)
        let defaultWindow = BrowserWindowState(tabs: [BrowserTabState(url: nil)])
        store.save(BrowserSession(windows: [defaultWindow, workWindow, goneWindow], savedAt: Date()))
        profiles.remove(id: gone.id)

        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.profileID) == [BrowserProfile.defaultID, work.id, gone.id])
        // Restoring opens each window in its profile; Gone's in Default.
        #expect(loaded.windows.map { profiles.resolvedID($0.profileID) } == [
            BrowserProfile.defaultID, work.id, BrowserProfile.defaultID,
        ])
    }

    @Test func windowsWithoutAProfileIdBelongToDefault() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            #"{"version": 2, "windows": [{"tabs": [{"url": "https://example.com"}]}, {"tabs": [{"url": "https://webkit.org"}], "profileID": "not-a-uuid"}], "savedAt": "2026-10-01T10:00:00Z"}"#,
            to: store,
            in: directory
        )
        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.profileID) == [BrowserProfile.defaultID, BrowserProfile.defaultID])
    }

    @Test func versionOneMigratesToOneWindowAndKeepsTheOldFile() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = """
        {
          "version": 1,
          "tabs": [
            { "url": "https://example.com", "title": "Example", "zoom": 1 },
            { "url": "https://webkit.org", "title": "WebKit", "interactionState": "YXJjaGl2ZQ==" }
          ],
          "selectedIndex": 1,
          "savedAt": "2023-11-14T22:13:20Z",
          "closedTabs": [
            { "url": "https://example.com/old", "title": "Old" },
            { "url": "https://example.com/newer", "title": "Newer" }
          ]
        }
        """
        try write(original, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.version == 1)
        let window = try #require(loaded.windows.first)
        #expect(loaded.windows.count == 1)
        #expect(window.frame == nil)
        #expect(window.selectedIndex == 1)
        #expect(window.tabs == [
            BrowserTabState(url: "https://example.com", title: "Example", zoom: 1),
            BrowserTabState(url: "https://webkit.org", title: "WebKit", zoom: 1, interactionState: Data("archive".utf8)),
        ])
        #expect(loaded.activeWindowIndex == 0)
        // The closed tabs keep their order (newest last) and return to the
        // migrated window.
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://example.com/old", title: "Old"), windowID: window.id, index: nil),
            .tab(BrowserTabState(url: "https://example.com/newer", title: "Newer"), windowID: window.id, index: nil),
        ])
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))

        // The next save is version 2; the kept file stays the original.
        store.save(BrowserSession(windows: loaded.windows, recentlyClosed: loaded.recentlyClosed, savedAt: Date()))
        let resaved = try #require(store.load())
        #expect(resaved.version == 2)
        #expect(resaved.windows == loaded.windows)
        #expect(resaved.recentlyClosed == loaded.recentlyClosed)
        #expect(try Data(contentsOf: store.migratedURL) == Data(original.utf8))
    }

    @Test func versionOneWithoutTabsMigratesToNoWindowAndHomelessClosedTabs() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        { "tabs": [], "selectedIndex": 0, "closedTabs": [{ "url": "https://example.com/a", "title": "A" }] }
        """, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.windows.isEmpty)
        #expect(loaded.activeWindowIndex == nil)
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://example.com/a", title: "A"), windowID: nil, index: nil),
        ])
    }

    @Test func entriesThatDoNotDecodeAreSkipped() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        {
          "version": 2,
          "windows": [
            { "tabs": [{ "url": "https://example.com", "title": "Example" }], "selectedIndex": 0 },
            42
          ],
          "recentlyClosed": [
            { "kind": "split-view", "tabs": [] },
            { "kind": "tab", "tab": { "url": "https://webkit.org", "title": "WebKit" }, "index": 3 }
          ],
          "savedAt": "2023-11-14T22:13:20Z"
        }
        """, to: store, in: directory)

        let loaded = try #require(store.load())
        #expect(loaded.windows.map(\.tabs) == [[BrowserTabState(url: "https://example.com", title: "Example")]])
        #expect(loaded.windows.first?.frame == nil)
        #expect(loaded.recentlyClosed.map(\.content) == [
            .tab(BrowserTabState(url: "https://webkit.org", title: "WebKit"), windowID: nil, index: 3),
        ])
    }

    @Test func notYetLoadedTabKeepsAddressAndHistoryThroughASave() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BrowserTabState(url: "https://example.com/b", title: "B", zoom: 1.25, interactionState: history)
        // A lazy tab's empty web view has no URL and no history of its own.
        let state = BrowserTabState.snapshot(
            pending: saved,
            isStartPage: false,
            failedURL: nil,
            currentURL: nil,
            title: "B",
            zoom: 1.25,
            interactionState: {
                Issue.record("A lazy tab must not read its empty web view's history")
                return nil
            }
        )
        store.save(BrowserSession(windows: [BrowserWindowState(tabs: [state])], savedAt: Date()))
        #expect(store.load()?.windows.first?.tabs == [saved])
    }

    @Test func loadedTabSavesItsLiveAddressAndHistory() {
        let state = BrowserTabState.snapshot(
            pending: nil,
            isStartPage: false,
            failedURL: nil,
            currentURL: "https://example.com/c",
            title: "C",
            zoom: 1,
            interactionState: { history }
        )
        #expect(state == BrowserTabState(url: "https://example.com/c", title: "C", zoom: 1, interactionState: history))
    }
}
