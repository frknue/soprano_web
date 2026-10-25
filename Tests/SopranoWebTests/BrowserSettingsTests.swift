@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSettingsStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSettings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultsAreSensible() {
        let settings = BrowserSettings.default
        #expect(settings.searchEngine == .duckDuckGo)
        #expect(settings.themeID == "folio")
        #expect(settings.restoreSession)
        #expect(settings.usesVerticalTabs)
        #expect(settings.downloadDirectoryURL.lastPathComponent == "Downloads")
    }

    @Test func olderSettingsWithoutVerticalTabsStartVertical() throws {
        let json = Data("""
        {
          "searchEngine": "duckDuckGo",
          "homepage": "",
          "themeID": "folio",
          "appearance": "system",
          "restoreSession": true
        }
        """.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
        #expect(settings.usesVerticalTabs)
    }

    @Test func updatePersistsAndNotifies() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = BrowserSettingsStore(url: url)
        var notifications = 0
        let observation = store.changes.observe { _ in notifications += 1 }
        defer { observation.cancel() }

        store.update {
            $0.searchEngine = .google
            $0.homepage = "https://example.com"
            $0.restoreSession = false
        }
        #expect(notifications == 1)

        let reloaded = BrowserSettingsStore(url: url)
        #expect(reloaded.settings.searchEngine == .google)
        #expect(reloaded.settings.homepage == "https://example.com")
        #expect(!reloaded.settings.restoreSession)
    }

    @Test func unchangedUpdateDoesNotWriteOrNotify() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"))
        var notifications = 0
        let observation = store.changes.observe { _ in notifications += 1 }
        defer { observation.cancel() }
        store.update { $0.searchEngine = .duckDuckGo }
        #expect(notifications == 0)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func settingsFileWithMissingKeysKeepsThePresentValues() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data("""
        { "searchEngine": "google", "homepage": "https://example.com", "verticalTabs": false }
        """.utf8).write(to: url)

        let settings = BrowserSettingsStore(url: url).settings
        #expect(settings.searchEngine == .google)
        #expect(settings.homepage == "https://example.com")
        #expect(!settings.usesVerticalTabs)
        #expect(settings.themeID == BrowserSettings.default.themeID)
        #expect(settings.restoreSession)
    }

    @Test func unknownSearchEngineFallsBackOnlyForThatKey() throws {
        let json = Data("""
        {
          "searchEngine": "altavista",
          "homepage": "https://example.com",
          "themeID": "folio-ink",
          "appearance": "dark",
          "restoreSession": false,
          "futureSetting": 3
        }
        """.utf8)
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: json)
        #expect(settings.searchEngine == .duckDuckGo)
        #expect(settings.homepage == "https://example.com")
        #expect(settings.themeID == "folio-ink")
        #expect(settings.appearance == .dark)
        #expect(!settings.restoreSession)
    }

    @Test func unreadableSettingsFileIsPreservedOnTheNextSave() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let broken = Data("{ \"searchEngine\": \"google\", ".utf8)
        try broken.write(to: url)
        let store = BrowserSettingsStore(url: url)
        try Data("older".utf8).write(to: store.unreadableURL)

        #expect(store.settings == .default)
        #expect(try Data(contentsOf: url) == broken)

        store.update { $0.searchEngine = .bing }
        #expect(store.unreadableURL.lastPathComponent == "settings.json.unreadable")
        #expect(try Data(contentsOf: store.unreadableURL) == broken)
        #expect(BrowserSettingsStore(url: url).settings.searchEngine == .bing)

        store.update { $0.homepage = "https://example.com" }
        #expect(try Data(contentsOf: store.unreadableURL) == broken)
    }
}

@MainActor
struct BrowserSessionStoreTests {
    @Test func sessionRoundTrips() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(url: directory.appendingPathComponent("session.json"))
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = BrowserSession(
            windows: [BrowserWindowState(
                tabs: [
                    BrowserTabState(url: nil, title: "New Tab", zoom: 1),
                    BrowserTabState(url: "https://example.com", title: "Example", zoom: 1.2),
                ],
                selectedIndex: 1
            )],
            savedAt: savedAt
        )
        store.save(session)
        let loaded = store.load()
        #expect(loaded == session)
    }

    @Test func sessionWithoutVersionOrZoomLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.json")
        try Data("""
        {
          "tabs": [
            { "url": "https://example.com", "title": "Example" },
            { "title": "New Tab" }
          ],
          "selectedIndex": 1,
          "savedAt": "2023-11-14T22:13:20Z"
        }
        """.utf8).write(to: url)

        let loaded = try #require(BrowserSessionStore(url: url).load())
        #expect(loaded.version == 1)
        #expect(loaded.windows.first?.selectedIndex == 1)
        #expect(loaded.windows.first?.tabs == [
            BrowserTabState(url: "https://example.com", title: "Example", zoom: 1),
            BrowserTabState(url: nil, title: "New Tab", zoom: 1),
        ])
    }
}
