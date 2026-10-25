import Foundation

/// One visit to add in bulk (the `history.json` migration, imports).
struct BrowserHistoryImport: Sendable {
    var url: String
    var title: String
    var visitedAt: Date
    var kind: BrowserVisitKind
}

/// History's SQL on one connection: the schema, writes and indexed reads.
/// Not bound to an actor, so the daily maintenance can run it on its own
/// connection off the main thread.
///
/// `urls` holds one row per address with its title, visit and typed
/// counts, last visit and frecency; `display` is the address as the address
/// bar matches it (lowercased, no scheme, no `www.`). `visits` holds one row
/// per visit with its time and `BrowserVisitKind`. Two FTS5 indexes over
/// title and display serve word starts (`urls_words`) and substrings
/// (`urls_trigram`); triggers keep them in step with `urls`.
final class BrowserHistoryDatabase {
    static let schemaVersion: Int64 = 1
    /// Candidates per match kind for the address bar.
    static let candidateLimit = 24
    /// A repeat of the newest visit this soon merges into it.
    static let mergeWindow: TimeInterval = 300
    /// Frecency updates per transaction during maintenance, so a visit
    /// recorded meanwhile waits milliseconds, not the whole pass.
    static let maintenanceBatch = 1_000

    let sql: BrowserSQLite

    init(path: String) throws {
        sql = try BrowserSQLite(path: path)
        try sql.execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        PRAGMA temp_store = MEMORY;
        """)
        try createSchema()
    }

    // MARK: Schema

    private func createSchema() throws {
        let version = try sql.scalar("PRAGMA user_version") ?? 0
        if version < Self.schemaVersion {
            try sql.transaction {
                try sql.execute("""
                CREATE TABLE IF NOT EXISTS urls (
                    id INTEGER PRIMARY KEY,
                    url TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL DEFAULT '',
                    display TEXT NOT NULL,
                    visit_count INTEGER NOT NULL DEFAULT 0,
                    typed_count INTEGER NOT NULL DEFAULT 0,
                    last_visit REAL NOT NULL,
                    frecency REAL NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS urls_display ON urls(display);
                CREATE INDEX IF NOT EXISTS urls_frecency ON urls(frecency DESC);
                CREATE INDEX IF NOT EXISTS urls_last_visit ON urls(last_visit DESC);
                CREATE TABLE IF NOT EXISTS visits (
                    id INTEGER PRIMARY KEY,
                    url_id INTEGER NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
                    visited_at REAL NOT NULL,
                    transition INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS visits_time ON visits(visited_at);
                CREATE INDEX IF NOT EXISTS visits_url ON visits(url_id, visited_at);
                CREATE VIRTUAL TABLE IF NOT EXISTS urls_words USING fts5(
                    title, display, content='urls', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 0', prefix='1 2'
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS urls_trigram USING fts5(
                    title, display, content='urls', content_rowid='id', tokenize='trigram'
                );
                CREATE TRIGGER IF NOT EXISTS urls_index_insert AFTER INSERT ON urls BEGIN
                    INSERT INTO urls_words(rowid, title, display) VALUES (new.id, new.title, new.display);
                    INSERT INTO urls_trigram(rowid, title, display) VALUES (new.id, new.title, new.display);
                END;
                CREATE TRIGGER IF NOT EXISTS urls_index_delete AFTER DELETE ON urls BEGIN
                    INSERT INTO urls_words(urls_words, rowid, title, display)
                        VALUES ('delete', old.id, old.title, old.display);
                    INSERT INTO urls_trigram(urls_trigram, rowid, title, display)
                        VALUES ('delete', old.id, old.title, old.display);
                END;
                CREATE TRIGGER IF NOT EXISTS urls_index_update AFTER UPDATE OF title ON urls
                WHEN old.title IS NOT new.title BEGIN
                    INSERT INTO urls_words(urls_words, rowid, title, display)
                        VALUES ('delete', old.id, old.title, old.display);
                    INSERT INTO urls_trigram(urls_trigram, rowid, title, display)
                        VALUES ('delete', old.id, old.title, old.display);
                    INSERT INTO urls_words(rowid, title, display) VALUES (new.id, new.title, new.display);
                    INSERT INTO urls_trigram(rowid, title, display) VALUES (new.id, new.title, new.display);
                END;
                PRAGMA user_version = \(Self.schemaVersion);
                """)
            }
        }
        try sql.execute("CREATE TEMP TABLE IF NOT EXISTS touched (id INTEGER PRIMARY KEY)")
    }

    /// The address as the address bar matches it: lowercased, without
    /// `http(s)://` and `www.`.
    static func display(_ url: String) -> String {
        AddressURLText.display(url).lowercased()
    }

    // MARK: Writes

    /// Adds a visit, or merges it into the newest visit when that is the
    /// same address less than `mergeWindow` earlier (a reload or a quick
    /// repeat): the title and time follow, and a typed repeat makes it typed.
    func record(url: String, title: String, at date: Date, kind: BrowserVisitKind, now: Date) throws {
        try sql.transaction {
            var newest: (visit: Int64, urlID: Int64, time: Double, kind: Int64, url: String)?
            try sql.query("""
            SELECT v.id, v.url_id, v.visited_at, v.transition, u.url
            FROM visits v JOIN urls u ON u.id = v.url_id
            ORDER BY v.visited_at DESC, v.id DESC LIMIT 1
            """) { row in
                newest = (row.int(0), row.int(1), row.double(2), row.int(3), row.text(4))
            }
            let time = date.timeIntervalSince1970
            if let newest, newest.url == url, time >= newest.time, time - newest.time < Self.mergeWindow {
                let becomesTyped = kind == .typed && newest.kind != Int64(BrowserVisitKind.typed.rawValue)
                try sql.run(
                    "UPDATE visits SET visited_at = ?1, transition = ?2 WHERE id = ?3",
                    [.double(time), .int(becomesTyped ? Int64(BrowserVisitKind.typed.rawValue) : newest.kind), .int(newest.visit)]
                )
                try sql.run("""
                UPDATE urls SET
                    title = CASE WHEN ?1 <> '' THEN ?1 ELSE title END,
                    last_visit = max(last_visit, ?2),
                    typed_count = typed_count + ?3
                WHERE id = ?4
                """, [.text(title), .double(time), .int(becomesTyped ? 1 : 0), .int(newest.urlID)])
                try refreshFrecency(urlID: newest.urlID, now: now)
                return
            }
            let urlID = try insertVisit(url: url, title: title, time: time, kind: kind)
            try refreshFrecency(urlID: urlID, now: now)
        }
    }

    /// Adds every visit as is (no merging) and refreshes frecency.
    func importVisits(_ visits: [BrowserHistoryImport], now: Date) throws {
        guard !visits.isEmpty else { return }
        try sql.transaction {
            for visit in visits.sorted(by: { $0.visitedAt < $1.visitedAt }) {
                _ = try insertVisit(
                    url: visit.url,
                    title: visit.title,
                    time: visit.visitedAt.timeIntervalSince1970,
                    kind: visit.kind
                )
            }
        }
        try refreshAllFrecency(now: now)
    }

    private func insertVisit(url: String, title: String, time: Double, kind: BrowserVisitKind) throws -> Int64 {
        let typed: Int64 = kind == .typed ? 1 : 0
        guard let urlID = try sql.scalar("""
        INSERT INTO urls (url, title, display, visit_count, typed_count, last_visit)
        VALUES (?1, ?2, ?3, 1, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET
            title = CASE WHEN excluded.title <> '' AND excluded.last_visit >= urls.last_visit
                THEN excluded.title ELSE urls.title END,
            visit_count = urls.visit_count + 1,
            typed_count = urls.typed_count + excluded.typed_count,
            last_visit = max(urls.last_visit, excluded.last_visit)
        RETURNING id
        """, [.text(url), .text(title), .text(Self.display(url)), .int(typed), .double(time)])
        else {
            throw BrowserSQLite.Failure(code: 0, message: "no id for \(url)")
        }
        try sql.run(
            "INSERT INTO visits (url_id, visited_at, transition) VALUES (?1, ?2, ?3)",
            [.int(urlID), .double(time), .int(Int64(kind.rawValue))]
        )
        return urlID
    }

    /// Removes every visit to `url`.
    @discardableResult
    func removePage(url: String) throws -> Int {
        try sql.run("DELETE FROM urls WHERE url = ?1", [.text(url)])
    }

    /// Removes the visits at or after `date` (Clear Browsing Data).
    @discardableResult
    func removeVisits(since date: Date, now: Date) throws -> Int {
        try removeVisits(where: "visited_at >= ?1", date, now: now)
    }

    /// Removes the visits before `date` (retention).
    @discardableResult
    func removeVisits(before date: Date, now: Date) throws -> Int {
        try removeVisits(where: "visited_at < ?1", date, now: now)
    }

    /// Deletes matching visits, then pages left without visits, recounts
    /// the pages that kept some and refreshes their frecency. Returns the
    /// number of visits removed.
    private func removeVisits(where condition: String, _ date: Date, now: Date) throws -> Int {
        let bound: [BrowserSQLite.Value] = [.double(date.timeIntervalSince1970)]
        let (removed, kept): (Int, [Int64]) = try sql.transaction {
            try sql.run("DELETE FROM temp.touched")
            try sql.run("INSERT OR IGNORE INTO temp.touched (id) SELECT url_id FROM visits WHERE \(condition)", bound)
            let removed = try sql.run("DELETE FROM visits WHERE \(condition)", bound)
            guard removed > 0 else { return (0, []) }
            try sql.run("""
            DELETE FROM urls WHERE id IN (SELECT id FROM temp.touched)
                AND NOT EXISTS (SELECT 1 FROM visits WHERE url_id = urls.id)
            """)
            try sql.run("""
            UPDATE urls SET
                visit_count = (SELECT count(*) FROM visits WHERE url_id = urls.id),
                typed_count = (SELECT count(*) FROM visits WHERE url_id = urls.id AND transition = \(BrowserVisitKind.typed.rawValue)),
                last_visit = (SELECT max(visited_at) FROM visits WHERE url_id = urls.id)
            WHERE id IN (SELECT id FROM temp.touched)
            """)
            var ids: [Int64] = []
            try sql.query("SELECT t.id FROM temp.touched t JOIN urls u ON u.id = t.id") { ids.append($0.int(0)) }
            return (removed, ids)
        }
        for start in stride(from: 0, to: kept.count, by: Self.maintenanceBatch) {
            try sql.transaction {
                for id in kept[start..<min(kept.count, start + Self.maintenanceBatch)] {
                    try refreshFrecency(urlID: id, now: now)
                }
            }
        }
        return removed
    }

    // MARK: Frecency

    private func refreshFrecency(urlID: Int64, now: Date) throws {
        let count = try sql.scalar("SELECT visit_count FROM urls WHERE id = ?1", [.int(urlID)]) ?? 0
        var samples: [(date: Date, kind: BrowserVisitKind)] = []
        try sql.query(
            "SELECT visited_at, transition FROM visits WHERE url_id = ?1 ORDER BY visited_at DESC LIMIT \(BrowserFrecency.sampleSize)",
            [.int(urlID)]
        ) { row in
            samples.append((Date(timeIntervalSince1970: row.double(0)), BrowserVisitKind(rawValue: Int(row.int(1))) ?? .link))
        }
        let score = BrowserFrecency.score(visitCount: Int(count), samples: samples, now: now)
        try sql.run("UPDATE urls SET frecency = ?1 WHERE id = ?2", [.double(score), .int(urlID)])
    }

    /// Recomputes every page's frecency from one ordered pass over the
    /// visits index (recency buckets age, so this runs daily).
    func refreshAllFrecency(now: Date) throws {
        var scores: [(Int64, Double)] = []
        var currentID: Int64?
        var count = 0
        var samples: [(date: Date, kind: BrowserVisitKind)] = []
        func flush() {
            guard let currentID else { return }
            scores.append((currentID, BrowserFrecency.score(visitCount: count, samples: samples, now: now)))
        }
        try sql.query("SELECT url_id, visited_at, transition FROM visits ORDER BY url_id DESC, visited_at DESC") { row in
            let id = row.int(0)
            if id != currentID {
                flush()
                currentID = id
                count = 0
                samples.removeAll(keepingCapacity: true)
            }
            count += 1
            if samples.count < BrowserFrecency.sampleSize {
                samples.append((Date(timeIntervalSince1970: row.double(1)), BrowserVisitKind(rawValue: Int(row.int(2))) ?? .link))
            }
        }
        flush()
        for start in stride(from: 0, to: scores.count, by: Self.maintenanceBatch) {
            try sql.transaction {
                for (id, score) in scores[start..<min(scores.count, start + Self.maintenanceBatch)] {
                    try sql.run("UPDATE urls SET frecency = ?1 WHERE id = ?2", [.double(score), .int(id)])
                }
            }
        }
    }

    // MARK: Reads

    private static let pageColumns = "u.url, u.title, u.visit_count, u.typed_count, u.last_visit, u.frecency"

    private func pages(_ query: String, _ values: [BrowserSQLite.Value]) throws -> [BrowserHistoryPage] {
        var pages: [BrowserHistoryPage] = []
        try sql.query(query, values) { row in
            pages.append(BrowserHistoryPage(
                url: row.text(0),
                title: row.text(1),
                visits: Int(row.int(2)),
                typedVisits: Int(row.int(3)),
                lastVisit: Date(timeIntervalSince1970: row.double(4)),
                frecency: row.double(5)
            ))
        }
        return pages
    }

    /// The pages the address bar ranks for `query`, by frecency within each
    /// match kind: address prefixes (an index range on `display`), word
    /// starts in the title or address (`urls_words`), and substrings
    /// (`urls_trigram`, or a frecency-ordered scan under three characters).
    func suggestionCandidates(for query: String) throws -> [BrowserHistoryPage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let matcher = AddressQueryMatcher(query: trimmed)
        let limit = BrowserSQLite.Value.int(Int64(Self.candidateLimit))
        var result: [BrowserHistoryPage] = []
        var seen: Set<String> = []
        func add(_ pages: [BrowserHistoryPage]) {
            for page in pages where seen.insert(page.url).inserted {
                result.append(page)
            }
        }

        if let prefix = matcher.hostQuery {
            add(try pages("""
            SELECT \(Self.pageColumns) FROM urls u
            WHERE u.display >= ?1 AND u.display < ?2
            ORDER BY u.frecency DESC LIMIT ?3
            """, [.text(prefix), .text(prefix + "\u{10FFFF}"), limit]))
        }
        if let words = Self.wordExpression(matcher.terms) {
            add(try pages("""
            SELECT \(Self.pageColumns) FROM urls u
            WHERE u.id IN (SELECT rowid FROM urls_words WHERE urls_words MATCH ?1)
            ORDER BY u.frecency DESC LIMIT ?2
            """, [.text(words), limit]))
        }
        if trimmed.count >= 2 {
            add(try substringPages(matcher.terms, limit: limit))
        }
        return result
    }

    private func substringPages(_ terms: [String], limit: BrowserSQLite.Value) throws -> [BrowserHistoryPage] {
        guard !terms.isEmpty else { return [] }
        if terms.allSatisfy({ $0.count >= 3 }) {
            return try pages("""
            SELECT \(Self.pageColumns) FROM urls u
            WHERE u.id IN (SELECT rowid FROM urls_trigram WHERE urls_trigram MATCH ?1)
            ORDER BY u.frecency DESC LIMIT ?2
            """, [.text(Self.phraseExpression(terms)), limit])
        }
        let conditions = terms.indices
            .map { "(u.title || ' ' || u.display) LIKE ?\($0 + 1) ESCAPE '\\'" }
            .joined(separator: " AND ")
        return try pages("""
        SELECT \(Self.pageColumns) FROM urls u WHERE \(conditions)
        ORDER BY u.frecency DESC LIMIT ?\(terms.count + 1)
        """, terms.map { .text(Self.likePattern($0)) } + [limit])
    }

    /// The most recently visited pages, one row per address.
    func recentPages(limit: Int) throws -> [BrowserHistoryPage] {
        try pages(
            "SELECT \(Self.pageColumns) FROM urls u ORDER BY u.last_visit DESC LIMIT ?1",
            [.int(Int64(limit))]
        )
    }

    /// Visits newest first, older than `cursor` (the last visit of the
    /// previous page), whose title or address contains every word of
    /// `query`.
    func visits(matching query: String, before cursor: BrowserHistoryVisit?, limit: Int) throws -> [BrowserHistoryVisit] {
        let filter = Self.searchFilter(query, firstParameter: 4)
        var visits: [BrowserHistoryVisit] = []
        try sql.query("""
        SELECT v.id, v.visited_at, v.transition, u.url, u.title
        FROM visits v JOIN urls u ON u.id = v.url_id
        WHERE (v.visited_at, v.id) < (?1, ?2)\(filter.map { " AND v.url_id IN (\($0.sql))" } ?? "")
        ORDER BY v.visited_at DESC, v.id DESC LIMIT ?3
        """, [
            .double(cursor?.visitedAt.timeIntervalSince1970 ?? .greatestFiniteMagnitude),
            .int(cursor?.id ?? .max),
            .int(Int64(limit)),
        ] + (filter?.values ?? [])) { row in
            visits.append(BrowserHistoryVisit(
                id: row.int(0),
                url: row.text(3),
                title: row.text(4),
                visitedAt: Date(timeIntervalSince1970: row.double(1)),
                kind: BrowserVisitKind(rawValue: Int(row.int(2))) ?? .link
            ))
        }
        return visits
    }

    func visitCount(matching query: String) throws -> Int {
        let filter = Self.searchFilter(query, firstParameter: 1)
        let sql = filter.map { "SELECT count(*) FROM visits WHERE url_id IN (\($0.sql))" } ?? "SELECT count(*) FROM visits"
        return Int(try self.sql.scalar(sql, filter?.values ?? []) ?? 0)
    }

    func pageCount() throws -> Int {
        Int(try sql.scalar("SELECT count(*) FROM urls") ?? 0)
    }

    // MARK: Query text

    /// The ids of pages whose title or address contains every word.
    private static func searchFilter(_ query: String, firstParameter: Int) -> (sql: String, values: [BrowserSQLite.Value])? {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nil }
        if terms.allSatisfy({ $0.count >= 3 }) {
            return (
                "SELECT rowid FROM urls_trigram WHERE urls_trigram MATCH ?\(firstParameter)",
                [.text(phraseExpression(terms))]
            )
        }
        let conditions = terms.indices
            .map { "(title || ' ' || display) LIKE ?\(firstParameter + $0) ESCAPE '\\'" }
            .joined(separator: " AND ")
        return ("SELECT id FROM urls WHERE \(conditions)", terms.map { .text(likePattern($0)) })
    }

    /// `"alp"* "news"*`: every term as a word-start prefix. Terms split
    /// into words the way the `unicode61` tokenizer does.
    static func wordExpression(_ terms: [String]) -> String? {
        let phrases = terms.compactMap { term -> String? in
            let words = term.split { !$0.isLetter && !$0.isNumber }
            guard !words.isEmpty else { return nil }
            return "\"\(words.joined(separator: " "))\"*"
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: " ")
    }

    /// `"rust" "book"`: every term as a substring (trigram phrases).
    static func phraseExpression(_ terms: [String]) -> String {
        terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
    }

    static func likePattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
