@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserHistoryRetentionTests {
    private func berlin() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func cutoffsFollowTheCalendar() {
        // 2026-10-26 10:00 CET, the day after clocks went back.
        let now = date("2026-10-26T09:00:00Z")
        let calendar = berlin()
        #expect(BrowserHistoryRetention.oneDay.cutoff(now: now, calendar: calendar) == date("2026-10-25T09:00:00Z"))
        // A week ago it was 10:00 CEST, one hour earlier in UTC.
        #expect(BrowserHistoryRetention.oneWeek.cutoff(now: now, calendar: calendar) == date("2026-10-19T08:00:00Z"))
        #expect(BrowserHistoryRetention.twoWeeks.cutoff(now: now, calendar: calendar) == date("2026-10-12T08:00:00Z"))
        #expect(BrowserHistoryRetention.oneMonth.cutoff(now: now, calendar: calendar) == date("2026-09-26T08:00:00Z"))
        #expect(BrowserHistoryRetention.oneYear.cutoff(now: now, calendar: calendar) == date("2025-10-26T09:00:00Z"))
        #expect(BrowserHistoryRetention.manually.cutoff(now: now, calendar: calendar) == nil)
    }

    @Test func oneYearIsTheDefaultAndUnknownValuesFallBack() throws {
        #expect(BrowserSettings.default.historyRetention == .oneYear)
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"historyRetention": "forever"}"#.utf8))
        #expect(decoded.historyRetention == .oneYear)
        let week = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"historyRetention": "oneWeek"}"#.utf8))
        #expect(week.historyRetention == .oneWeek)
    }

    @Test func pruningRemovesVisitsBeforeTheCutoffOnly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = date("2026-10-26T09:00:00Z")
        let cutoff = try #require(BrowserHistoryRetention.oneWeek.cutoff(now: now, calendar: berlin()))
        store.importVisits([
            BrowserHistoryImport(url: "https://gone.example/", title: "Gone", visitedAt: cutoff.addingTimeInterval(-1), kind: .typed),
            BrowserHistoryImport(url: "https://edge.example/", title: "Edge", visitedAt: cutoff, kind: .link),
            BrowserHistoryImport(url: "https://mixed.example/", title: "Mixed", visitedAt: cutoff.addingTimeInterval(-86_400), kind: .typed),
            BrowserHistoryImport(url: "https://mixed.example/", title: "Mixed", visitedAt: now.addingTimeInterval(-60), kind: .link),
        ], now: now)

        let database = try BrowserHistoryDatabase(path: store.databaseURL.path)
        #expect(try BrowserHistoryStore.maintain(database, cutoff: cutoff, now: now) == 2)
        #expect(Set(store.visits(limit: 10).map(\.url)) == ["https://edge.example/", "https://mixed.example/"])
        let mixed = store.recentPages(limit: 10).first { $0.url == "https://mixed.example/" }
        #expect(mixed?.visits == 1)
        #expect(mixed?.typedVisits == 0)
        #expect(mixed?.frecency == 100)
        #expect(store.suggestionCandidates(for: "gone").isEmpty)
        // Nothing left to remove.
        #expect(try BrowserHistoryStore.maintain(database, cutoff: cutoff, now: now) == 0)
        // "Manually" keeps everything but still refreshes frecency.
        #expect(try BrowserHistoryStore.maintain(database, cutoff: nil, now: now.addingTimeInterval(200 * 86_400)) == 0)
        #expect(store.recentPages(limit: 10).allSatisfy { $0.frecency == 10 })
    }

    @Test func backgroundMaintenanceNotifiesWhenItRemovedVisits() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = Date()
        store.importVisits([
            BrowserHistoryImport(url: "https://old.example/", title: "Old", visitedAt: now.addingTimeInterval(-3 * 86_400), kind: .link),
            BrowserHistoryImport(url: "https://new.example/", title: "New", visitedAt: now.addingTimeInterval(-60), kind: .link),
        ], now: now)
        var notified = 0
        let token = store.changes.observe { notified += 1 }
        await withCheckedContinuation { continuation in
            store.runMaintenance(retention: .oneDay, now: now) { continuation.resume() }
        }
        #expect(notified == 1)
        #expect(store.visits(limit: 10).map(\.url) == ["https://new.example/"])
        token.cancel()
    }
}
