@testable import SopranoWeb
import AppKit
import Testing

/// Pin coding and stage 2's `bookmarks.json` (`BrowserBookmarksFile`), the
/// migration source of the Default profile's Space.
struct BrowserPinFileTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decodeBookmarks(_ json: String) throws -> BrowserBookmarksFile {
        try decoder().decode(BrowserBookmarksFile.self, from: Data(json.utf8))
    }

    @Test func version1ListDecodesIntoTheRootNewestFirst() throws {
        let old = UUID()
        let new = UUID()
        let file = try decodeBookmarks("""
        { "version": 1, "entries": [
          { "id": "\(old.uuidString)", "url": "https://old.example/", "title": "Old", "addedAt": "2023-01-01T00:00:00Z" },
          { "id": "\(new.uuidString)", "url": "https://new.example/", "title": "New", "addedAt": "2024-01-01T00:00:00Z" },
          { "url": "https://broken.example/" }
        ] }
        """)
        #expect(file.version == 1)
        #expect(file.tree.root.children.map(\.id) == [new, old])
        let allTopLevel = file.tree.entries().allSatisfy(\.path.isEmpty)
        #expect(allTopLevel)
    }

    @Test func stageOneBareArrayDecodesToo() throws {
        let file = try decodeBookmarks("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "addedAt": "2023-11-14T22:13:20Z" }]
        """)
        #expect(file.version == 1)
        #expect(file.tree.entries().map(\.pin.title) == ["Example"])
    }

    @Test func equalDatesKeepTheFileOrder() throws {
        let tree = try decodeBookmarks("""
        { "version": 1, "entries": [
          { "id": "\(UUID().uuidString)", "url": "https://1.example/", "title": "1", "addedAt": "2024-01-01T00:00:00Z" },
          { "id": "\(UUID().uuidString)", "url": "https://2.example/", "title": "2", "addedAt": "2024-01-01T00:00:00Z" },
          { "id": "\(UUID().uuidString)", "url": "https://3.example/", "title": "3", "addedAt": "2024-01-01T00:00:00Z" }
        ] }
        """).tree
        #expect(tree.root.children.map(\.title) == ["1", "2", "3"])
    }

    @Test func badNodesAreSkippedAndRepeatedIdsDropped() throws {
        let shared = UUID()
        let folder = UUID()
        let file = try decodeBookmarks("""
        { "version": 2, "root": { "type": "folder", "id": "\(UUID().uuidString)", "name": "Anything", "children": [
          { "type": "bookmark", "id": "\(shared.uuidString)", "url": "https://first.example/", "title": "First" },
          { "type": "pin", "id": "\(shared.uuidString)", "url": "https://second.example/", "title": "Second" },
          { "type": "bookmark", "title": "No address" },
          { "type": "bookmark", "url": "   ", "title": "Blank address" },
          { "type": "separator" },
          42,
          { "type": "folder", "id": "\(folder.uuidString)", "name": "Work", "children": [
            { "url": "https://inferred.example/", "title": "Inferred" },
            { "type": "folder", "id": "\(folder.uuidString)", "name": "Same id", "children": [
              { "type": "bookmark", "url": "https://lost.example/", "title": "Lost" }
            ] },
            { "type": "folder", "id": "\(BrowserPinTree.rootID.uuidString)", "name": "Root id" },
            { "children": [], "name": "Inferred folder" },
            { "type": "folder", "children": "not a list" }
          ] }
        ] } }
        """)
        let tree = file.tree
        #expect(file.version == 2)
        #expect(tree.root.id == BrowserPinTree.rootID)
        #expect(tree.root.name == BrowserPinTree.rootName)
        #expect(tree.root.children.map(\.title) == ["First", "Work"])
        let work = try #require(tree.folder(id: folder))
        #expect(work.children.map(\.title) == ["Inferred", "Inferred folder", "Untitled Folder"])
        #expect(work.children[0].pin?.title == "Inferred")
        #expect(work.children[2].folder?.children.isEmpty == true)
        #expect(tree.pins(url: "https://lost.example/").isEmpty)
    }

    @Test func treesRoundTripAsPinNodes() throws {
        let tree = BrowserPinTree(children: [
            .folder(BrowserPinFolder(
                name: "Work",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                children: [
                    .pin(BrowserPin(url: "https://a.example/", title: "A", addedAt: Date(timeIntervalSince1970: 1_700_000_100))),
                    .folder(BrowserPinFolder(name: "Empty", addedAt: Date(timeIntervalSince1970: 1_700_000_200))),
                ]
            )),
            .pin(BrowserPin(url: "https://b.example/", title: "", addedAt: Date(timeIntervalSince1970: 1_700_000_300))),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tree.root)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let children = object?["children"] as? [[String: Any]]
        #expect(children?.map { $0["type"] as? String } == ["folder", "pin"])

        let decoded = BrowserPinTree(root: try decoder().decode(BrowserPinFolder.self, from: data))
        #expect(decoded == tree)
    }
}
