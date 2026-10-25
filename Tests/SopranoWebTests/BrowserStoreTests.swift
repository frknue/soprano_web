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
        let bookmarksURL = directory.appendingPathComponent("bookmarks.json")
        let downloadsURL = directory.appendingPathComponent("downloads.json")
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "addedAt": "2023-11-14T22:13:20Z" }]
        """.utf8).write(to: bookmarksURL)
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com/a.zip", "filename": "a.zip",
           "path": "/tmp/a.zip", "startedAt": "2023-11-14T22:13:20Z", "state": "completed",
           "fractionCompleted": 1 }]
        """.utf8).write(to: downloadsURL)

        let bookmarks = BrowserBookmarkStore(url: bookmarksURL)
        let downloads = BrowserDownloadStore(url: downloadsURL)
        #expect(bookmarks.bookmarks.map(\.title) == ["Example"])
        #expect(downloads.records.map(\.filename) == ["a.zip"])

        bookmarks.toggle(url: "https://webkit.org", title: "WebKit")
        let download = downloads.begin(url: "https://example.com/b.zip", filename: "b.zip")
        downloads.finish(id: download.id, path: "/tmp/b.zip")

        for url in [bookmarksURL, downloadsURL] {
            let file = try envelope(at: url)
            #expect(file.version == 1)
            #expect(file.count == 2)
        }
    }
}
