@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserBookmarkFileTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebBookmarks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func object(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func decode(_ json: String) throws -> BrowserBookmarkTree {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserBookmarkFile.self, from: Data(json.utf8)).tree
    }

    @Test func version1ListMigratesIntoTheRootNewestFirstAndKeepsTheOldFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        let old = UUID()
        let new = UUID()
        let original = """
        { "version": 1, "entries": [
          { "id": "\(old.uuidString)", "url": "https://old.example/", "title": "Old", "addedAt": "2023-01-01T00:00:00Z" },
          { "id": "\(new.uuidString)", "url": "https://new.example/", "title": "New", "addedAt": "2024-01-01T00:00:00Z" },
          { "url": "https://broken.example/" }
        ] }
        """
        try Data(original.utf8).write(to: url)

        let store = BrowserBookmarkStore(url: url)
        #expect(store.tree.root.children.map(\.id) == [new, old])
        let allTopLevel = store.entries.allSatisfy(\.path.isEmpty)
        #expect(allTopLevel)
        #expect(try String(contentsOf: store.migratedURL, encoding: .utf8) == original)

        let file = try object(at: url)
        #expect(file["version"] as? Int == 2)
        let root = file["root"] as? [String: Any]
        #expect((root?["children"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["New", "Old"])
        #expect((root?["children"] as? [[String: Any]])?.first?["type"] as? String == "bookmark")

        // Once: reopening reads version 2 and leaves the kept file alone.
        store.addFolder(name: "Work")
        let reopened = BrowserBookmarkStore(url: url)
        #expect(reopened.tree.root.children.map(\.title) == ["New", "Old", "Work"])
        #expect(try String(contentsOf: reopened.migratedURL, encoding: .utf8) == original)
    }

    @Test func stageOneBareArrayMigratesToo() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "addedAt": "2023-11-14T22:13:20Z" }]
        """.utf8).write(to: url)

        let store = BrowserBookmarkStore(url: url)
        #expect(store.bookmarks.map(\.title) == ["Example"])
        #expect(FileManager.default.fileExists(atPath: store.migratedURL.path))
        #expect(try object(at: url)["version"] as? Int == 2)
    }

    @Test func equalDatesKeepTheFileOrderWhenMigrating() throws {
        let tree = try decode("""
        { "version": 1, "entries": [
          { "id": "\(UUID().uuidString)", "url": "https://1.example/", "title": "1", "addedAt": "2024-01-01T00:00:00Z" },
          { "id": "\(UUID().uuidString)", "url": "https://2.example/", "title": "2", "addedAt": "2024-01-01T00:00:00Z" },
          { "id": "\(UUID().uuidString)", "url": "https://3.example/", "title": "3", "addedAt": "2024-01-01T00:00:00Z" }
        ] }
        """)
        #expect(tree.root.children.map(\.title) == ["1", "2", "3"])
    }

    @Test func badNodesAreSkippedAndRepeatedIdsDropped() throws {
        let shared = UUID()
        let folder = UUID()
        let tree = try decode("""
        { "version": 2, "root": { "type": "folder", "id": "\(UUID().uuidString)", "name": "Anything", "children": [
          { "type": "bookmark", "id": "\(shared.uuidString)", "url": "https://first.example/", "title": "First" },
          { "type": "bookmark", "id": "\(shared.uuidString)", "url": "https://second.example/", "title": "Second" },
          { "type": "bookmark", "title": "No address" },
          { "type": "bookmark", "url": "   ", "title": "Blank address" },
          { "type": "separator" },
          42,
          { "type": "folder", "id": "\(folder.uuidString)", "name": "Work", "children": [
            { "url": "https://inferred.example/", "title": "Inferred" },
            { "type": "folder", "id": "\(folder.uuidString)", "name": "Same id", "children": [
              { "type": "bookmark", "url": "https://lost.example/", "title": "Lost" }
            ] },
            { "type": "folder", "id": "\(BrowserBookmarkTree.rootID.uuidString)", "name": "Root id" },
            { "children": [], "name": "Inferred folder" },
            { "type": "folder", "children": "not a list" }
          ] }
        ] } }
        """)
        #expect(tree.root.id == BrowserBookmarkTree.rootID)
        #expect(tree.root.name == "Bookmarks")
        #expect(tree.root.children.map(\.title) == ["First", "Work"])
        let work = try #require(tree.folder(id: folder))
        #expect(work.children.map(\.title) == ["Inferred", "Inferred folder", "Untitled Folder"])
        #expect(work.children[0].bookmark?.title == "Inferred")
        #expect(work.children[2].folder?.children.isEmpty == true)
        #expect(tree.bookmarks(url: "https://lost.example/").isEmpty)
    }

    @Test func aDamagedFileIsKeptAndTheStoreStartsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        try Data("{ not json".utf8).write(to: url)

        let store = BrowserBookmarkStore(url: url)
        #expect(store.tree.isEmpty)
        #expect(try String(contentsOf: store.corruptURL, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: store.migratedURL.path))
    }

    @Test func treesRoundTripThroughTheFile() throws {
        let tree = BrowserBookmarkTree(children: [
            .folder(BrowserBookmarkFolder(
                name: "Work",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                children: [
                    .bookmark(BrowserBookmark(url: "https://a.example/", title: "A", addedAt: Date(timeIntervalSince1970: 1_700_000_100))),
                    .folder(BrowserBookmarkFolder(name: "Empty", addedAt: Date(timeIntervalSince1970: 1_700_000_200))),
                ]
            )),
            .bookmark(BrowserBookmark(url: "https://b.example/", title: "", addedAt: Date(timeIntervalSince1970: 1_700_000_300))),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(BrowserBookmarkFile(tree: tree))
        let decoded = try decode(String(decoding: data, as: UTF8.self))
        #expect(decoded == tree)
    }
}
