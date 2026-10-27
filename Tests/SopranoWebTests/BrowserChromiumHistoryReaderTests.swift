@testable import SopranoWeb
import AppKit
import SQLite3
import Testing

struct BrowserChromiumHistoryReaderTests {
    private struct Stop: Error {}

    private func temporaryDirectory(_ name: String = "SopranoWebTests-\(UUID().uuidString)") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Chromium's schema (the columns the reader uses, as Chrome declares them).
    private let schema = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
        CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL,
            visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL,
            segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL);
        CREATE INDEX visits_time_index ON visits (visit_time);
        """

    /// Writes a History database at `url` with `sql` run after the schema.
    private func makeHistory(at url: URL, _ sql: String) {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, schema + sql, nil, nil, &error)
        if let error {
            Issue.record("SQLite: \(String(cString: error))")
            sqlite3_free(error)
        }
        #expect(code == SQLITE_OK)
    }

    /// 13 000 000 000 000 000 µs after 1601-01-01 is 2012-12-15 00:00:00 UTC.
    private let base: Int64 = 13_000_000_000_000_000
    private let baseDate = Date(timeIntervalSince1970: 1_355_526_400)

    @Test func chromiumTimeConvertsBothWays() {
        #expect(BrowserChromiumTime.date(microseconds: base) == baseDate)
        #expect(BrowserChromiumTime.microseconds(baseDate) == base)
        #expect(BrowserChromiumTime.date(microseconds: 0) == Date(timeIntervalSince1970: -11_644_473_600))
    }

    @Test func readsVisitsOldestFirstSkippingHiddenSubframesAndInternalSchemes() throws {
        // A folder name with the characters SQLite's URI parser treats specially.
        let directory = temporaryDirectory("SopranoWebTests #1 ?100% \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History")
        makeHistory(at: file, """
            INSERT INTO urls(id, url, title, last_visit_time, hidden) VALUES
                (1, 'https://a.example/', 'A', 0, 0),
                (2, 'https://hidden.example/', 'Hidden', 0, 1),
                (3, 'chrome://settings/', 'Settings', 0, 0),
                (4, 'https://frame.example/', 'Frame', 0, 0),
                (5, 'http://b.example/', NULL, 0, 0);
            INSERT INTO visits(url, visit_time, transition) VALUES
                (1, \(base + 2_000_000), 0),
                (1, \(base + 1_000_000), \(0x3000_0001)),
                (2, \(base + 3_000_000), 1),
                (3, \(base + 4_000_000), 1),
                (4, \(base + 5_000_000), 3),
                (4, \(base + 6_000_000), \(0x0800_0004)),
                (5, \(base + 7_000_000), 8),
                (4, \(base + 8_000_000), 0);
            """)

        var batches: [[BrowserImportedVisit]] = []
        try BrowserChromiumHistoryReader(fileURL: file).read { batches.append($0) }
        #expect(batches == [[
            BrowserImportedVisit(url: "https://a.example/", title: "A", visitedAt: baseDate.addingTimeInterval(1), typed: true),
            BrowserImportedVisit(url: "https://a.example/", title: "A", visitedAt: baseDate.addingTimeInterval(2)),
            BrowserImportedVisit(url: "http://b.example/", title: "", visitedAt: baseDate.addingTimeInterval(7)),
            BrowserImportedVisit(url: "https://frame.example/", title: "Frame", visitedAt: baseDate.addingTimeInterval(8)),
        ]])

        // The database is opened immutable: no journal or WAL appears.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["History"])
    }

    @Test func streamsInBatchesFromASinceDate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History")
        makeHistory(at: file, """
            INSERT INTO urls(id, url, title, last_visit_time) VALUES (1, 'https://a.example/', 'A', 0);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2500)
            INSERT INTO visits(url, visit_time, transition) SELECT 1, \(base) + i * 1000000, 0 FROM n;
            """)
        let reader = BrowserChromiumHistoryReader(fileURL: file)

        var sizes: [Int] = []
        var last: Date?
        try reader.read(batchSize: 1_000) { batch in
            sizes.append(batch.count)
            for visit in batch {
                if let last { #expect(visit.visitedAt > last) }
                last = visit.visitedAt
            }
        }
        #expect(sizes == [1_000, 1_000, 500])

        var count = 0
        var first: Date?
        try reader.read(since: baseDate.addingTimeInterval(2_001), batchSize: 0) { batch in
            if first == nil { first = batch.first?.visitedAt }
            count += batch.count
        }
        #expect(count == 500)
        #expect(first == baseDate.addingTimeInterval(2_001))
    }

    @Test func aThrowingCallbackStopsTheRead() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History")
        makeHistory(at: file, """
            INSERT INTO urls(id, url, title, last_visit_time) VALUES (1, 'https://a.example/', 'A', 0);
            INSERT INTO visits(url, visit_time, transition) VALUES (1, \(base), 0), (1, \(base + 1), 0);
            """)
        var calls = 0
        #expect(throws: Stop.self) {
            try BrowserChromiumHistoryReader(fileURL: file).read(batchSize: 1) { _ in
                calls += 1
                throw Stop()
            }
        }
        #expect(calls == 1)
    }

    @Test func missingAndDamagedFilesThrow() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History")
        #expect(throws: BrowserImportError.missingFile(file)) {
            try BrowserChromiumHistoryReader(fileURL: file).read { _ in }
        }

        try Data("not a database, just text that is long enough to have a header".utf8).write(to: file)
        var unreadable = false
        do {
            try BrowserChromiumHistoryReader(fileURL: file).read { _ in }
        } catch let error as BrowserImportError {
            if case .unreadable = error { unreadable = true }
        }
        #expect(unreadable)
    }

    @Test func uriEscapesPercentQuestionMarkAndHash() {
        let uri = BrowserChromiumHistoryReader.immutableURI(for: URL(fileURLWithPath: "/tmp/a b/100%?#/History"))
        #expect(uri == "file:/tmp/a b/100%25%3f%23/History?immutable=1")
    }
}
