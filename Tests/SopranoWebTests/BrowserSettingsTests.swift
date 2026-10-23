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
        store.onChange = { _ in notifications += 1 }

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
        store.onChange = { _ in notifications += 1 }
        store.update { $0.searchEngine = .duckDuckGo }
        #expect(notifications == 0)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
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
            tabs: [
                BrowserTabState(url: nil, title: "New Tab", zoom: 1),
                BrowserTabState(url: "https://example.com", title: "Example", zoom: 1.2),
            ],
            selectedIndex: 1,
            savedAt: savedAt
        )
        store.save(session)
        let loaded = store.load()
        #expect(loaded == session)
    }
}
