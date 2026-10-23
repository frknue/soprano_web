@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func historyDeduplicatesRecentVisitsAndPersists() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = BrowserHistoryStore(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        store.record(url: "https://example.com", title: "Example", at: date)
        store.record(url: "https://example.com", title: "Example again", at: date.addingTimeInterval(30))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].title == "Example again")

        store.record(url: "https://example.com/other", title: "Other", at: date.addingTimeInterval(60))
        #expect(store.entries.count == 2)

        let reloaded = BrowserHistoryStore(url: url)
        #expect(reloaded.entries.count == 2)
        #expect(reloaded.entries[0].url == "https://example.com/other")
    }

    @Test func historyRespectsLimit() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(url: directory.appendingPathComponent("history.json"), limit: 2)
        store.record(url: "https://a.example", title: "A")
        store.record(url: "https://b.example", title: "B")
        store.record(url: "https://c.example", title: "C")
        #expect(store.entries.count == 2)
        #expect(store.entries.map(\.url) == ["https://c.example", "https://b.example"])
    }

    @Test func bookmarksToggleAndPersist() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        let store = BrowserBookmarkStore(url: url)

        #expect(store.toggle(url: "https://example.com", title: "Example"))
        #expect(store.isBookmarked("https://example.com"))
        #expect(!store.toggle(url: "https://example.com", title: "Example"))
        #expect(store.bookmarks.isEmpty)

        _ = store.toggle(url: "https://example.com", title: "Example")
        let reloaded = BrowserBookmarkStore(url: url)
        #expect(reloaded.bookmarks.count == 1)
        #expect(reloaded.bookmarks[0].title == "Example")
    }

    @Test func downloadsPersistOnlyFinishedRecords() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let store = BrowserDownloadStore(url: url)

        let finished = store.begin(url: "https://example.com/file.zip", filename: "file.zip")
        store.finish(id: finished.id, path: "/tmp/file.zip")
        _ = store.begin(url: "https://example.com/other.zip", filename: "other.zip")

        let reloaded = BrowserDownloadStore(url: url)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records[0].filename == "file.zip")
        #expect(reloaded.records[0].state == .completed)
        #expect(reloaded.records[0].path == "/tmp/file.zip")
    }

    @Test func downloadProgressIsInMemoryUntilFinished() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/large.pdf", filename: "large.pdf")
        store.updateProgress(id: record.id, fraction: 0.42)
        #expect(store.records[0].fractionCompleted == 0.42)

        store.finish(id: record.id, path: "/tmp/large.pdf")
        #expect(store.records[0].fractionCompleted == 1)
        store.updateProgress(id: record.id, fraction: 0.1)
        #expect(store.records[0].fractionCompleted == 1)
    }

    @Test func failedDownloadKeepsTheError() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let record = store.begin(url: "https://example.com/bad", filename: "bad")
        store.fail(id: record.id, message: "No route to host")
        #expect(store.records[0].state == .failed)
        #expect(store.records[0].errorMessage == "No route to host")
    }

    private func envelope(at url: URL) throws -> (version: Int?, count: Int?) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (object?["version"] as? Int, (object?["entries"] as? [Any])?.count)
    }

    @Test func legacyBareArrayListsLoadAndAreRewrittenAsEnvelopes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let bookmarksURL = directory.appendingPathComponent("bookmarks.json")
        let downloadsURL = directory.appendingPathComponent("downloads.json")
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "visitedAt": "2023-11-14T22:13:20Z" }]
        """.utf8).write(to: historyURL)
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "addedAt": "2023-11-14T22:13:20Z" }]
        """.utf8).write(to: bookmarksURL)
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com/a.zip", "filename": "a.zip",
           "path": "/tmp/a.zip", "startedAt": "2023-11-14T22:13:20Z", "state": "completed",
           "fractionCompleted": 1 }]
        """.utf8).write(to: downloadsURL)

        let history = BrowserHistoryStore(url: historyURL)
        let bookmarks = BrowserBookmarkStore(url: bookmarksURL)
        let downloads = BrowserDownloadStore(url: downloadsURL)
        #expect(history.entries.map(\.url) == ["https://example.com"])
        #expect(bookmarks.bookmarks.map(\.title) == ["Example"])
        #expect(downloads.records.map(\.filename) == ["a.zip"])

        history.record(url: "https://webkit.org", title: "WebKit")
        bookmarks.toggle(url: "https://webkit.org", title: "WebKit")
        let download = downloads.begin(url: "https://example.com/b.zip", filename: "b.zip")
        downloads.finish(id: download.id, path: "/tmp/b.zip")

        for url in [historyURL, bookmarksURL, downloadsURL] {
            let file = try envelope(at: url)
            #expect(file.version == 1)
            #expect(file.count == 2)
        }
        #expect(BrowserHistoryStore(url: historyURL).entries.count == 2)
    }

    @Test func oneCorruptHistoryEntryDoesNotDropTheOthers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try Data("""
        { "version": 1, "entries": [
          { "id": "\(UUID().uuidString)", "url": "https://a.example", "title": "A",
            "visitedAt": "2023-11-14T22:13:20Z" },
          { "id": "not-a-uuid", "url": 42 },
          null,
          { "id": "\(UUID().uuidString)", "url": "https://b.example", "title": "B",
            "visitedAt": "2023-11-14T22:14:20Z" }
        ] }
        """.utf8).write(to: url)

        let store = BrowserHistoryStore(url: url)
        #expect(store.entries.map(\.url) == ["https://b.example", "https://a.example"])
    }
}
