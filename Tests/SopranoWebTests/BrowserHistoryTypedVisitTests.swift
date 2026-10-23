@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserHistoryTypedVisitTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func typedFlagPersistsAndSurvivesARepeatVisit() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = BrowserHistoryStore(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        store.record(url: "https://example.com/", title: "Example", at: date, typed: true)
        // A reload within five minutes merges into the typed visit.
        store.record(url: "https://example.com/", title: "Example", at: date.addingTimeInterval(30))
        store.record(url: "https://example.com/a", title: "A", at: date.addingTimeInterval(60))

        let reloaded = BrowserHistoryStore(url: url)
        #expect(reloaded.entries.map(\.typed) == [nil, true])
        let stats = AddressSuggestionEngine.visitStats(reloaded.entries)
        #expect(stats.first { $0.url == "https://example.com/" }?.typedVisits == 1)
    }

    @Test func oldEntriesAndMalformedFlagsStillLoad() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let json = """
        {"version": 1, "entries": [
          {"id": "\(UUID().uuidString)", "url": "https://old.example/", "title": "Old",
           "visitedAt": "2024-01-02T03:04:05Z"},
          {"id": "\(UUID().uuidString)", "url": "https://odd.example/", "title": "Odd",
           "visitedAt": "2024-01-02T03:04:06Z", "typed": "yes"},
          {"id": "\(UUID().uuidString)", "url": "https://typed.example/", "title": "Typed",
           "visitedAt": "2024-01-02T03:04:07Z", "typed": true}
        ]}
        """
        try Data(json.utf8).write(to: url)

        let store = BrowserHistoryStore(url: url)
        #expect(store.entries.map(\.url) == [
            "https://typed.example/",
            "https://odd.example/",
            "https://old.example/",
        ])
        #expect(store.entries.map(\.typed) == [true, nil, nil])
    }
}
