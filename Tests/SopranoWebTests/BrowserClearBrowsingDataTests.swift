@testable import SopranoWeb
import AppKit
import Testing
import WebKit

@MainActor
struct BrowserClearBrowsingDataTests {
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

    @Test func rangesStartAtTheHourOrLocalMidnight() {
        // 29 March 2026 is the spring-forward day in Berlin: "today" must
        // start at local midnight, not 24 hours ago.
        let now = date("2026-03-29T08:30:00Z") // 10:30 CEST
        let calendar = berlin()
        #expect(BrowserClearRange.lastHour.startDate(now: now, calendar: calendar) == date("2026-03-29T07:30:00Z"))
        #expect(BrowserClearRange.today.startDate(now: now, calendar: calendar) == date("2026-03-28T23:00:00Z"))
        #expect(
            BrowserClearRange.todayAndYesterday.startDate(now: now, calendar: calendar)
                == date("2026-03-27T23:00:00Z")
        )
        #expect(BrowserClearRange.allTime.startDate(now: now, calendar: calendar) == .distantPast)
    }

    @Test func historyRemovalKeepsVisitsBeforeTheRange() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHistoryStore(directory: directory)
        let now = date("2026-10-23T12:00:00Z")
        store.record(url: "https://old.example", title: "Old", at: date("2026-10-21T21:59:00Z"))
        store.record(url: "https://yesterday.example", title: "Yesterday", at: date("2026-10-22T21:00:00Z"))
        store.record(url: "https://today.example", title: "Today", at: date("2026-10-23T09:00:00Z"))
        store.record(url: "https://recent.example", title: "Recent", at: date("2026-10-23T11:30:00Z"))
        // An older visit to a page that also has one inside the range.
        store.record(url: "https://today.example", title: "Today", at: date("2026-10-23T11:45:00Z"))

        store.removeVisits(since: BrowserClearRange.lastHour.startDate(now: now, calendar: berlin()), now: now)
        #expect(store.visits(limit: 10).map(\.url) == [
            "https://today.example", "https://yesterday.example", "https://old.example",
        ])
        let today = store.recentPages(limit: 10).first { $0.url == "https://today.example" }
        #expect(today?.visits == 1)
        #expect(today?.lastVisit == date("2026-10-23T09:00:00Z"))
        #expect(store.pageCount() == 3)

        store.removeVisits(since: BrowserClearRange.todayAndYesterday.startDate(now: now, calendar: berlin()), now: now)
        #expect(BrowserHistoryStore(directory: directory).visits(limit: 10).map(\.url) == ["https://old.example"])
        store.removeVisits(since: BrowserClearRange.allTime.startDate(now: now), now: now)
        #expect(BrowserHistoryStore(directory: directory).visitCount() == 0)
        #expect(store.pageCount() == 0)
        #expect(store.suggestionCandidates(for: "old").isEmpty)
    }

    @Test func cookiesCheckboxRemovesSiteDataButNotCaches() {
        let available = WKWebsiteDataStore.allWebsiteDataTypes()
        let options = BrowserClearOptions(cookiesAndSiteData: true, cachedFiles: false)
        let types = options.websiteDataTypes(available: available)
        #expect(types.contains(WKWebsiteDataTypeCookies))
        #expect(types.contains(WKWebsiteDataTypeLocalStorage))
        #expect(types.contains(WKWebsiteDataTypeIndexedDBDatabases))
        #expect(types.contains(WKWebsiteDataTypeServiceWorkerRegistrations))
        #expect(types.isDisjoint(with: BrowserClearOptions.cacheTypes))
    }

    @Test func cacheCheckboxRemovesOnlyCaches() {
        let available = WKWebsiteDataStore.allWebsiteDataTypes()
        let options = BrowserClearOptions(cookiesAndSiteData: false, cachedFiles: true)
        let types = options.websiteDataTypes(available: available)
        #expect(types.contains(WKWebsiteDataTypeDiskCache))
        #expect(types.contains(WKWebsiteDataTypeMemoryCache))
        #expect(!types.contains(WKWebsiteDataTypeCookies))
        #expect(types.isSubset(of: BrowserClearOptions.cacheTypes))
    }

    @Test func bothDataCheckboxesCoverEveryTypeAndHistoryAloneTouchesNone() {
        let available = WKWebsiteDataStore.allWebsiteDataTypes()
        let both = BrowserClearOptions(cookiesAndSiteData: true, cachedFiles: true)
        #expect(both.websiteDataTypes(available: available) == available)

        let historyOnly = BrowserClearOptions(history: true, cookiesAndSiteData: false, cachedFiles: false)
        #expect(historyOnly.websiteDataTypes(available: available).isEmpty)
        #expect(!historyOnly.isEmpty)
        let nothing = BrowserClearOptions(history: false, cookiesAndSiteData: false, cachedFiles: false)
        #expect(nothing.isEmpty)
    }

    @Test func defaultsClearHistoryCookiesAndCacheForTheLastHour() {
        let options = BrowserClearOptions()
        #expect(options.range == .lastHour)
        #expect(options.history && options.cookiesAndSiteData && options.cachedFiles)
        #expect(!options.downloadList)
    }

    @Test func downloadListRemovalKeepsActiveAndOlderDownloads() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let cutoff = Date().addingTimeInterval(-1)
        let finished = store.begin(url: "https://example.com/a.zip", filename: "a.zip")
        store.finish(id: finished.id, path: "/tmp/a.zip")
        let active = store.begin(url: "https://example.com/b.zip", filename: "b.zip")

        store.removeFinished(startedSince: Date().addingTimeInterval(60))
        #expect(store.records.count == 2)
        store.removeFinished(startedSince: cutoff)
        #expect(store.records.map(\.id) == [active.id])
    }

    @Test func websiteDataKindsReadAsUserLabels() {
        let labels = BrowserWebsiteDataKinds.labels(for: [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage,
            "WKUnknownFutureType",
        ])
        #expect(labels == ["Cookies", "Local storage", "Cache"])
        #expect(BrowserWebsiteDataKinds.labels(for: []).isEmpty)
    }
}
