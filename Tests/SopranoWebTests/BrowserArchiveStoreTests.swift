@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserArchiveStoreTests {
    private let work = UUID()
    private let space = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebArchive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func archive(
        _ store: BrowserArchiveStore,
        _ url: String,
        title: String = "",
        profile: UUID = BrowserProfile.defaultID,
        ago: TimeInterval = 0
    ) -> BrowserArchiveEntry? {
        store.archive(
            url: url,
            title: title,
            spaceID: space,
            profileID: profile,
            at: now.addingTimeInterval(-ago),
            reason: .manual
        )
    }

    // MARK: File

    @Test func entriesAreSavedAtOnceAndReadBackNewestFirst() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let store = BrowserArchiveStore(url: url)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        archive(store, "https://a.example/", title: "A", ago: 60)
        archive(store, "https://b.example/", title: "B", ago: 0)
        archive(store, "https://c.example/", title: "C", ago: 120)

        let reopened = BrowserArchiveStore(url: url)
        #expect(reopened.entries.map(\.title) == ["B", "A", "C"])
        #expect(reopened.entries == store.entries)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect((object?["entries"] as? [Any])?.count == 3)
    }

    @Test func decodingSkipsBadEntriesAndKeepsTheFirstOfARepeatedID() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let id = UUID().uuidString
        let profile = BrowserProfile.defaultID.uuidString
        try write("""
        {"version": 1, "entries": [
          {"id": "\(id)", "url": "https://first.example/", "title": "First", "profileID": "\(profile)",
           "archivedAt": "2026-10-20T10:00:00Z", "reason": "auto", "spaceID": "\(space.uuidString)", "faviconKey": "first.example"},
          {"id": "\(id)", "url": "https://repeat.example/", "profileID": "\(profile)", "archivedAt": "2026-10-21T10:00:00Z"},
          {"id": "not-a-uuid", "url": "https://bad.example/", "profileID": "\(profile)", "archivedAt": "2026-10-21T10:00:00Z"},
          {"id": "\(UUID().uuidString)", "url": "  ", "profileID": "\(profile)", "archivedAt": "2026-10-21T10:00:00Z"},
          {"id": "\(UUID().uuidString)", "url": "https://noprofile.example/", "archivedAt": "2026-10-21T10:00:00Z"},
          {"id": "\(UUID().uuidString)", "url": "https://nodate.example/", "profileID": "\(profile)"},
          {"id": "\(UUID().uuidString)", "url": "https://plain.example/", "profileID": "\(profile)",
           "archivedAt": "2026-10-22T10:00:00Z", "reason": "someday"},
          42
        ]}
        """, to: url)

        let store = BrowserArchiveStore(url: url)

        #expect(store.entries.map(\.url) == ["https://plain.example/", "https://first.example/"])
        let plain = try #require(store.entries.first)
        #expect(plain.title == "")
        #expect(plain.reason == .manual)
        #expect(plain.spaceID == nil)
        #expect(plain.displayTitle == "plain.example")
        let first = try #require(store.entries.last)
        #expect(first.reason == .auto)
        #expect(first.spaceID == space)
        #expect(first.faviconKey == "first.example")
        #expect(!FileManager.default.fileExists(atPath: store.corruptURL.path))
    }

    @Test func anUnreadableFileIsKeptAsCorruptAndTheArchiveStartsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        try write("{ not json", to: url)

        let store = BrowserArchiveStore(url: url)

        #expect(store.entries.isEmpty)
        #expect(try String(contentsOf: store.corruptURL, encoding: .utf8) == "{ not json")
        // The damaged file is replaced, so the next launch reads cleanly
        // and keeps the copy.
        #expect(JSONFile.read(BrowserArchiveFile.self, at: url)?.entries.isEmpty == true)
        archive(store, "https://after.example/")
        #expect(BrowserArchiveStore(url: url).entries.map(\.url) == ["https://after.example/"])
        #expect(try String(contentsOf: store.corruptURL, encoding: .utf8) == "{ not json")
    }

    // MARK: Archiving

    @Test func theSamePageArchivedAgainMovesToTheTopOncePerProfile() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserArchiveStore(url: directory.appendingPathComponent("archive.json"))
        archive(store, "https://a.example/", title: "Old", ago: 600)
        archive(store, "https://b.example/", ago: 300)
        archive(store, "https://a.example/", title: "Work copy", profile: work, ago: 200)
        archive(store, "https://a.example/", title: "New", ago: 0)

        #expect(store.entries.map(\.title) == ["New", "Work copy", ""])
        #expect(store.entries(ofProfile: BrowserProfile.defaultID).map(\.url) == ["https://a.example/", "https://b.example/"])
    }

    @Test func startPagesAndNonWebAddressesAreNotArchived() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserArchiveStore(url: directory.appendingPathComponent("archive.json"))
        #expect(archive(store, "soprano://start") == nil)
        #expect(archive(store, "about:blank") == nil)
        #expect(archive(store, "data:text/plain,hi") == nil)
        #expect(archive(store, "") == nil)
        #expect(archive(store, "file:///tmp/page.html") != nil)
        #expect(archive(store, "http://127.0.0.1:8080/a.html") != nil)
        #expect(store.entries.count == 2)
    }

    @Test func importedEntriesKeepTheirTimesSkipKnownIDsAndTakeTheReason() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserArchiveStore(url: directory.appendingPathComponent("archive.json"))
        let existing = archive(store, "https://kept.example/", ago: 100)!
        let older = BrowserArchiveEntry(
            url: "https://arc.example/old",
            title: "Old Arc tab",
            spaceID: nil,
            profileID: BrowserProfile.defaultID,
            archivedAt: now.addingTimeInterval(-86_400),
            reason: .auto
        )
        let newer = BrowserArchiveEntry(
            url: "https://arc.example/new",
            title: "New Arc tab",
            spaceID: space,
            profileID: BrowserProfile.defaultID,
            archivedAt: now,
            reason: .manual
        )

        let added = store.insert([older, newer, newer, existing], reason: .imported)

        #expect(added == 2)
        #expect(store.entries.map(\.title) == ["New Arc tab", "", "Old Arc tab"])
        #expect(store.entries.map(\.reason) == [.imported, .manual, .imported])
        #expect(store.insert([older], reason: .imported) == 0)
    }

    // MARK: Search

    @Test func searchIgnoresCaseAndDiacriticsAndMatchesTitleOrAddress() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserArchiveStore(url: directory.appendingPathComponent("archive.json"))
        archive(store, "https://www.procope.com/menu", title: "Café Procope — Menu", ago: 30)
        archive(store, "https://en.wikipedia.org/wiki/Caf%C3%A9", title: "Café - Wikipedia", ago: 20)
        archive(store, "https://webkit.org/blog/", title: "WebKit Blog", ago: 10)
        archive(store, "https://cafe.example/", title: "Work's café", profile: work)

        func titles(_ query: String, _ profile: UUID = BrowserProfile.defaultID) -> [String] {
            store.search(query, inProfile: profile).map(\.title)
        }
        #expect(titles("cafe") == ["Café - Wikipedia", "Café Procope — Menu"])
        #expect(titles("CAFÉ") == ["Café - Wikipedia", "Café Procope — Menu"])
        #expect(titles("procope") == ["Café Procope — Menu"])
        // Address only.
        #expect(titles("webkit.org/blog") == ["WebKit Blog"])
        #expect(titles("wikipedia.org") == ["Café - Wikipedia"])
        // Every word, anywhere.
        #expect(titles("menu cafe") == ["Café Procope — Menu"])
        #expect(titles("menu wiki").isEmpty)
        // An empty query lists the profile's entries, newest first.
        #expect(titles("  ") == ["WebKit Blog", "Café - Wikipedia", "Café Procope — Menu"])
        #expect(titles("cafe", work) == ["Work's café"])
    }

    // MARK: Removing

    @Test func removingAnEntryAProfileAndATimeRange() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let store = BrowserArchiveStore(url: url)
        var notified = 0
        let observation = store.changes.observe { notified += 1 }
        defer { observation.cancel() }
        let hour: TimeInterval = 3_600
        let recent = archive(store, "https://recent.example/", ago: 0.5 * hour)!
        archive(store, "https://edge.example/", ago: hour)
        archive(store, "https://old.example/", ago: 30 * hour)
        archive(store, "https://work-recent.example/", profile: work, ago: 0.5 * hour)
        archive(store, "https://work-old.example/", profile: work, ago: 30 * hour)
        #expect(notified == 5)

        // Clear Browsing Data ▸ last hour, for Default: the bounds count.
        store.removeEntries(ofProfile: BrowserProfile.defaultID, archivedIn: now.addingTimeInterval(-hour)...now)
        #expect(store.entries(ofProfile: BrowserProfile.defaultID).map(\.url) == ["https://old.example/"])
        #expect(store.entries(ofProfile: work).count == 2)
        #expect(store.entry(id: recent.id) == nil)

        // Nothing in the range: no write, no notification.
        let before = notified
        store.removeEntries(ofProfile: work, archivedIn: now.addingTimeInterval(-10 * hour)...now.addingTimeInterval(-2 * hour))
        #expect(notified == before)

        let old = store.entries(ofProfile: BrowserProfile.defaultID)[0]
        #expect(store.remove(id: old.id)?.url == "https://old.example/")
        #expect(store.remove(id: old.id) == nil)

        // The profile is deleted.
        store.removeEntries(ofProfile: work)
        #expect(store.entries.isEmpty)
        #expect(BrowserArchiveStore(url: url).entries.isEmpty)
    }

    // MARK: Sidebar rows

    @Test func theArchiveListHasADayHeaderBeforeEachNewDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        func entry(_ hoursAgo: Double) -> BrowserArchiveEntry {
            BrowserArchiveEntry(
                url: "https://example.com/\(hoursAgo)",
                title: "\(hoursAgo)",
                spaceID: nil,
                profileID: BrowserProfile.defaultID,
                archivedAt: noon.addingTimeInterval(-hoursAgo * 3_600),
                reason: .auto
            )
        }
        let rows = BrowserSidebarView.archiveRows([entry(1), entry(2), entry(20), entry(80)], now: noon, calendar: calendar)
        let shown = rows.map { row -> String in
            switch row {
            case let .day(title): "# \(title)"
            case let .archived(entry): entry.title
            default: "?"
            }
        }
        #expect(shown == ["# Today", "1.0", "2.0", "# Yesterday", "20.0", "# Saturday", "80.0"])
    }
}
