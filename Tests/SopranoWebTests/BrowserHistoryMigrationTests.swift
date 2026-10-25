@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserHistoryMigrationTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacy(_ directory: URL) -> URL {
        directory.appendingPathComponent("history.json")
    }

    private func migrated(_ directory: URL) -> URL {
        directory.appendingPathComponent("history.json.migrated")
    }

    @Test func envelopeMigratesOnceWithTypedFlagsAndIsKept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"version": 1, "entries": [
          {"id": "\(UUID().uuidString)", "url": "https://typed.example/", "title": "Typed",
           "visitedAt": "2024-01-02T03:04:07Z", "typed": true},
          {"id": "\(UUID().uuidString)", "url": "https://odd.example/", "title": "Odd",
           "visitedAt": "2024-01-02T03:04:06Z", "typed": "yes"},
          {"id": "not-a-uuid", "url": 42},
          null,
          {"id": "\(UUID().uuidString)", "url": "https://typed.example/", "title": "",
           "visitedAt": "2024-01-02T03:04:05Z"}
        ]}
        """
        try Data(json.utf8).write(to: legacy(directory))

        let store = BrowserHistoryStore(directory: directory)
        #expect(store.visits(limit: 10).map(\.url) == [
            "https://typed.example/", "https://odd.example/", "https://typed.example/",
        ])
        #expect(store.visits(limit: 10).map(\.kind) == [.typed, .link, .link])
        let typed = store.recentPages(limit: 5).first { $0.url == "https://typed.example/" }
        #expect(typed?.visits == 2)
        #expect(typed?.typedVisits == 1)
        #expect(typed?.title == "Typed")
        #expect(!FileManager.default.fileExists(atPath: legacy(directory).path))
        #expect(FileManager.default.fileExists(atPath: migrated(directory).path))

        // Opening again does not import a second time.
        #expect(BrowserHistoryStore(directory: directory).visitCount() == 3)
    }

    @Test func legacyBareArrayMigrates() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        [{ "id": "\(UUID().uuidString)", "url": "https://example.com", "title": "Example",
           "visitedAt": "2023-11-14T22:13:20Z" }]
        """.utf8).write(to: legacy(directory))

        let store = BrowserHistoryStore(directory: directory)
        let visits = store.visits(limit: 10)
        #expect(visits.map(\.url) == ["https://example.com"])
        #expect(visits.first?.visitedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(FileManager.default.fileExists(atPath: migrated(directory).path))
    }

    @Test func corruptFileStartsEmptyAndIsKept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: legacy(directory))

        let store = BrowserHistoryStore(directory: directory)
        #expect(store.visitCount() == 0)
        #expect(FileManager.default.fileExists(atPath: migrated(directory).path))
        store.record(url: "https://example.com/", title: "Example")
        #expect(BrowserHistoryStore(directory: directory).visitCount() == 1)
    }

    @Test func missingFileStartsEmpty() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        #expect(store.visitCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: migrated(directory).path))
    }
}
