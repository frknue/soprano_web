import Foundation
import SQLite3

/// Chromium's timestamps: microseconds since 1601-01-01 UTC (History's
/// `visit_time`, `Bookmarks`' `date_added`).
enum BrowserChromiumTime {
    /// Seconds from 1601-01-01 to 1970-01-01.
    static let epochOffset: Int64 = 11_644_473_600

    /// Converted in integers first, so the double keeps microsecond precision.
    static func date(microseconds: Int64) -> Date {
        let unixMicroseconds = microseconds &- epochOffset * 1_000_000
        return Date(timeIntervalSince1970: Double(unixMicroseconds) / 1_000_000)
    }

    static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) + epochOffset * 1_000_000
    }
}

/// Reads a Chromium `History` database (Chrome, Arc) without writing to it or
/// its journal: the file is opened `immutable`, so a running browser's lock
/// and WAL are ignored (visits only in an uncheckpointed WAL are missed).
/// Run it off the main thread: a profile can hold 10⁵ visits and more.
struct BrowserChromiumHistoryReader: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Calls `body` with visits, oldest first, in batches of at most
    /// `batchSize`. Skips hidden URLs, subframe navigations and URLs that are
    /// not http(s) or file. `since` keeps only visits at or after it. A
    /// throwing `body` stops the read and rethrows.
    func read(
        since: Date? = nil,
        batchSize: Int = 5_000,
        _ body: ([BrowserImportedVisit]) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrowserImportError.missingFile(fileURL)
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(Self.immutableURI(for: fileURL), &db, flags, nil)
        defer { sqlite3_close_v2(db) }
        guard code == SQLITE_OK, let db else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, code))
        }

        // Core transitions (`transition & 0xFF`): 1 typed, 3 auto subframe,
        // 4 manual subframe.
        let sql = """
            SELECT urls.url, urls.title, visits.visit_time, visits.transition & 255
            FROM visits JOIN urls ON urls.id = visits.url
            WHERE urls.hidden = 0
              AND (visits.transition & 255) NOT IN (3, 4)
              AND visits.visit_time >= ?
            ORDER BY visits.visit_time
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, prepared))
        }
        let lowerBound = since.map(BrowserChromiumTime.microseconds) ?? Int64.min
        sqlite3_bind_int64(statement, 1, lowerBound)

        let limit = max(1, batchSize)
        var batch: [BrowserImportedVisit] = []
        batch.reserveCapacity(limit)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw BrowserImportError.unreadable(fileURL, Self.message(db, step))
            }
            let url = Self.text(statement, 0)
            guard BrowserImportedVisit.isImportable(url) else { continue }
            batch.append(BrowserImportedVisit(
                url: url,
                title: Self.text(statement, 1),
                visitedAt: BrowserChromiumTime.date(microseconds: sqlite3_column_int64(statement, 2)),
                typed: sqlite3_column_int64(statement, 3) == 1
            ))
            if batch.count == limit {
                try body(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try body(batch) }
    }

    /// What an import plan shows before it runs.
    struct Counts: Sendable, Equatable {
        /// Every row of `visits`.
        var visits: Int
        /// What `read` yields without `since` (the same filters, schemes
        /// matched in SQL).
        var importable: Int
        /// What `read(since:)` yields.
        var kept: Int
    }

    func counts(since: Date? = nil) throws -> Counts {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrowserImportError.missingFile(fileURL)
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(Self.immutableURI(for: fileURL), &db, flags, nil)
        defer { sqlite3_close_v2(db) }
        guard code == SQLITE_OK, let db else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, code))
        }
        let sql = """
            SELECT
              (SELECT count(*) FROM visits),
              count(*),
              coalesce(sum(visits.visit_time >= ?), 0)
            FROM visits JOIN urls ON urls.id = visits.url
            WHERE urls.hidden = 0
              AND (visits.transition & 255) NOT IN (3, 4)
              AND (urls.url LIKE 'http:%' OR urls.url LIKE 'https:%' OR urls.url LIKE 'file:%')
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, prepared))
        }
        sqlite3_bind_int64(statement, 1, since.map(BrowserChromiumTime.microseconds) ?? Int64.min)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BrowserImportError.unreadable(fileURL, Self.message(db, sqlite3_errcode(db)))
        }
        return Counts(
            visits: Int(sqlite3_column_int64(statement, 0)),
            importable: Int(sqlite3_column_int64(statement, 1)),
            kept: Int(sqlite3_column_int64(statement, 2))
        )
    }

    /// `file:<path>?immutable=1`, with the characters SQLite's URI parser
    /// treats specially (`%`, `?`, `#`) escaped in the path.
    static func immutableURI(for fileURL: URL) -> String {
        var path = ""
        for character in fileURL.standardizedFileURL.path {
            switch character {
            case "%": path += "%25"
            case "?": path += "%3f"
            case "#": path += "%23"
            default: path.append(character)
            }
        }
        return "file:\(path)?immutable=1"
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func message(_ db: OpaquePointer?, _ code: Int32) -> String {
        if let db, let message = sqlite3_errmsg(db) { return "SQLite \(code): \(String(cString: message))" }
        return "SQLite \(code): \(String(cString: sqlite3_errstr(code)))"
    }
}
