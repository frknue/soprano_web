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

    @Test func bookmarksAndFoldersPersist() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        let store = BrowserBookmarkStore(url: url)

        let example = store.addBookmark(url: "https://example.com", title: "Example")
        #expect(store.isBookmarked("https://example.com"))
        store.remove(id: example.id)
        #expect(store.bookmarks.isEmpty)

        let work = store.addFolder(name: "Work")
        store.addBookmark(url: "https://example.com", title: "Example", to: work.id)
        let reloaded = BrowserBookmarkStore(url: url)
        #expect(reloaded.bookmarks.map(\.title) == ["Example"])
        #expect(reloaded.entries.first?.path == ["Work"])
        #expect(reloaded.tree.folder(id: work.id)?.name == "Work")
    }

    @Test func bookmarkSearchMatchesTitlesAddressesAndFolderNames() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserBookmarkStore(url: directory.appendingPathComponent("bookmarks.json"))
        let work = store.addFolder(name: "Work")
        let docs = store.addFolder(name: "Docs", in: work.id)
        store.addBookmark(url: "https://developer.apple.com/documentation/webkit", title: "WebKit", to: docs.id)
        store.addBookmark(url: "https://example.com", title: "Example")

        #expect(store.matching("webkit").map(\.pathText) == ["Work › Docs"])
        #expect(store.matching("example.com").map(\.pathText) == ["Bookmarks"])
        #expect(store.matching("work").map(\.bookmark.title) == ["WebKit"])
        #expect(store.matching(" ").count == 2)
    }

    @Test func bookmarkUIStateRemembersExpandedFoldersAndTheLastFolder() {
        let suite = "SopranoWebTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID()
        let docs = UUID()
        let state = BrowserBookmarkUIState(defaults: defaults)
        state.setExpanded(true, folder: work)
        state.setExpanded(true, folder: docs)
        state.setExpanded(false, folder: docs)
        state.lastFolderID = docs

        let reopened = BrowserBookmarkUIState(defaults: defaults)
        #expect(reopened.expandedFolders == [work])
        #expect(reopened.lastFolderID == docs)
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

    /// Bookmarks' bare arrays migrate to the version 2 tree
    /// (`BrowserBookmarkFileTests`).
    @Test func legacyBareArrayListsLoadAndAreRewrittenAsEnvelopes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloadsURL = directory.appendingPathComponent("downloads.json")
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com/a.zip", "filename": "a.zip",
           "path": "/tmp/a.zip", "startedAt": "2023-11-14T22:13:20Z", "state": "completed",
           "fractionCompleted": 1 }]
        """.utf8).write(to: downloadsURL)

        let downloads = BrowserDownloadStore(url: downloadsURL)
        #expect(downloads.records.map(\.filename) == ["a.zip"])

        let download = downloads.begin(url: "https://example.com/b.zip", filename: "b.zip")
        downloads.finish(id: download.id, path: "/tmp/b.zip")

        let file = try envelope(at: downloadsURL)
        #expect(file.version == 1)
        #expect(file.count == 2)
    }
}
