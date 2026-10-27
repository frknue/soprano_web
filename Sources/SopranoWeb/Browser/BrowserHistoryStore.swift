import Foundation

/// History: one SQLite database (`History.sqlite`, WAL) per directory, so a
/// profile gets its own by passing its folder. Everything that reads or
/// writes History goes through this store; `changes` fire after every
/// change. Reads are indexed and bounded (no whole-history load); the daily
/// retention pass and frecency refresh run on their own connection off the
/// main thread.
@MainActor
final class BrowserHistoryStore {
    nonisolated static let databaseName = "History.sqlite"
    /// Stage 1's JSON list, migrated once and kept as `history.json.migrated`.
    nonisolated static let legacyName = "history.json"

    let directory: URL
    let databaseURL: URL
    /// False when the database could not be opened even after moving a
    /// damaged file aside; History then lasts until quit.
    let isPersistent: Bool
    let changes = BrowserObservers<Void>()
    private let database: BrowserHistoryDatabase

    init(directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        databaseURL = directory.appendingPathComponent(Self.databaseName)
        if let opened = Self.open(databaseURL) {
            database = opened
            isPersistent = true
        } else {
            database = try! BrowserHistoryDatabase(path: ":memory:")
            isPersistent = false
        }
        migrateLegacyFile()
    }

    /// Opens the database; a file that is not one is kept as
    /// `History.sqlite.corrupt` and History starts over.
    private static func open(_ url: URL) -> BrowserHistoryDatabase? {
        if let database = try? BrowserHistoryDatabase(path: url.path) {
            return database
        }
        let fileManager = FileManager.default
        let damaged = url.appendingPathExtension("corrupt")
        try? fileManager.removeItem(at: damaged)
        try? fileManager.moveItem(at: url, to: damaged)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return try? BrowserHistoryDatabase(path: url.path)
    }

    /// Moves stage 1's `history.json` (envelope or bare array; unreadable
    /// entries skipped, an unreadable file adds nothing) into the database
    /// once, then renames it `history.json.migrated`.
    private func migrateLegacyFile() {
        let legacy = directory.appendingPathComponent(Self.legacyName)
        guard isPersistent, FileManager.default.fileExists(atPath: legacy.path) else { return }
        let entries = JSONFile.read(JSONList<BrowserHistoryJSONEntry>.self, at: legacy)?.entries ?? []
        do {
            try database.importVisits(entries.map(\.importValue), now: Date())
        } catch {
            report(error)
            return
        }
        let migrated = legacy.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migrated)
        try? FileManager.default.moveItem(at: legacy, to: migrated)
    }

    // MARK: Writing

    /// Records a visit to an `http`, `https` or `file` address. A repeat of
    /// the newest visit within five minutes merges into it.
    func record(url address: String, title: String, at date: Date = Date(), kind: BrowserVisitKind = .link) {
        guard let parsed = URL(string: address),
              ["http", "https", "file"].contains(parsed.scheme?.lowercased() ?? "")
        else { return }
        perform { try database.record(url: address, title: title, at: date, kind: kind, now: Date()) }
        changes.notify()
    }

    /// Adds visits in bulk without merging (migration, imports).
    func importVisits(_ visits: [BrowserHistoryImport], now: Date = Date()) {
        guard !visits.isEmpty else { return }
        perform { try database.importVisits(visits, now: now) }
        changes.notify()
    }

    /// An import's visits in bulk: `read` hands over batches (it runs off
    /// the main thread, so it may read another browser's database there);
    /// each batch goes into History in its own transaction on a second
    /// connection, skipping visits already there (same address and time),
    /// then every page's frecency is refreshed. `cancellation` stops it
    /// between batches (what was added stays). `progress` gets the visits
    /// handled so far; both callbacks run on the main actor.
    func importInBackground(
        batchesFrom read: @escaping @Sendable (_ body: ([BrowserHistoryImport]) throws -> Void) throws -> Void,
        cancellation: BrowserImportCancellation,
        progress: @escaping @MainActor @Sendable (Int) -> Void,
        completion: @escaping @MainActor @Sendable (Result<BrowserHistoryImportCount, Error>) -> Void
    ) {
        let now = Date()
        guard isPersistent else {
            let result = Result { try Self.importBatches(into: database, read: read, cancellation: cancellation, now: now) { _ in } }
            if (try? result.get())?.added ?? 0 > 0 { changes.notify() }
            completion(result)
            return
        }
        let path = databaseURL.path
        let finish: @MainActor @Sendable (Result<BrowserHistoryImportCount, Error>) -> Void = { [weak self] result in
            if (try? result.get())?.added ?? 0 > 0 { self?.changes.notify() }
            completion(result)
        }
        Task.detached(priority: .utility) {
            let result = Result {
                try Self.importBatches(
                    into: BrowserHistoryDatabase(path: path),
                    read: read,
                    cancellation: cancellation,
                    now: now
                ) { handled in
                    Task { @MainActor in progress(handled) }
                }
            }
            await finish(result)
        }
    }

    /// The import loop on `database` (any thread that owns it). A read or
    /// write error stops it like a cancel does: what was added stays,
    /// frecency is refreshed and the error comes back in `failure` with
    /// the counts. Only a failure to refresh frecency throws.
    nonisolated static func importBatches(
        into database: BrowserHistoryDatabase,
        read: (_ body: ([BrowserHistoryImport]) throws -> Void) throws -> Void,
        cancellation: BrowserImportCancellation,
        now: Date,
        progress: @escaping (Int) -> Void
    ) throws -> BrowserHistoryImportCount {
        var count = BrowserHistoryImportCount()
        do {
            try read { batch in
                if cancellation.isCancelled { throw CancellationError() }
                let result = try database.importNewVisits(batch)
                count.added += result.added
                count.skipped += result.skipped
                progress(count.added + count.skipped)
            }
        } catch is CancellationError {
            count.cancelled = true
        } catch {
            count.failure = "\(error)"
        }
        if count.added > 0 {
            try database.refreshAllFrecency(now: now)
        }
        return count
    }

    /// Removes every visit to `url` (the sidebar's Remove from History).
    func removePage(url: String) {
        guard (perform { try database.removePage(url: url) } ?? 0) > 0 else { return }
        changes.notify()
    }

    /// Removes the visits at or after `date` (Clear Browsing Data).
    func removeVisits(since date: Date, now: Date = Date()) {
        guard (perform { try database.removeVisits(since: date, now: now) } ?? 0) > 0 else { return }
        changes.notify()
    }

    // MARK: Reading

    /// Pages the address bar ranks for `query` (see
    /// `BrowserHistoryDatabase.suggestionCandidates`).
    func suggestionCandidates(for query: String) -> [BrowserHistoryPage] {
        perform { try database.suggestionCandidates(for: query) } ?? []
    }

    /// The most recently visited pages, one per address.
    func recentPages(limit: Int) -> [BrowserHistoryPage] {
        perform { try database.recentPages(limit: limit) } ?? []
    }

    /// One page of the History list: visits newest first after `cursor`.
    func visits(matching query: String = "", before cursor: BrowserHistoryVisit? = nil, limit: Int) -> [BrowserHistoryVisit] {
        perform { try database.visits(matching: query, before: cursor, limit: limit) } ?? []
    }

    func visitCount(matching query: String = "") -> Int {
        perform { try database.visitCount(matching: query) } ?? 0
    }

    func pageCount() -> Int {
        perform { try database.pageCount() } ?? 0
    }

    // MARK: Maintenance

    /// Removes visits older than `retention` allows and refreshes every
    /// page's frecency, on a background connection; `changes` fire when it
    /// removed something. `completion` runs on the main actor.
    func runMaintenance(
        retention: BrowserHistoryRetention,
        now: Date = Date(),
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let cutoff = retention.cutoff(now: now)
        guard isPersistent else {
            let removed = perform { try Self.maintain(database, cutoff: cutoff, now: now) } ?? 0
            if removed > 0 { changes.notify() }
            completion?()
            return
        }
        let path = databaseURL.path
        let finish: @MainActor @Sendable (Int) -> Void = { [weak self] removed in
            if removed > 0 { self?.changes.notify() }
            completion?()
        }
        Task.detached(priority: .utility) {
            let removed: Int
            do {
                removed = try Self.maintain(BrowserHistoryDatabase(path: path), cutoff: cutoff, now: now)
            } catch {
                removed = 0
                FileHandle.standardError.write(Data("History maintenance failed: \(error)\n".utf8))
            }
            await finish(removed)
        }
    }

    /// The retention pass on `database`: returns the visits removed.
    nonisolated static func maintain(_ database: BrowserHistoryDatabase, cutoff: Date?, now: Date) throws -> Int {
        let removed = try cutoff.map { try database.removeVisits(before: $0, now: now) } ?? 0
        try database.refreshAllFrecency(now: now)
        return removed
    }

    // MARK: Private

    private func perform<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("History: \(error)\n".utf8))
    }
}

/// What a bulk History import did.
struct BrowserHistoryImportCount: Sendable, Equatable {
    var added = 0
    /// Visits History already held (same address and time).
    var skipped = 0
    var cancelled = false
    /// The read or write error that stopped it, after `added` visits.
    var failure: String?
}

/// Stops a running import between batches; safe to use from any thread.
final class BrowserImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// One visit in stage 1's `history.json`. `typed` is optional and lossy: a
/// missing or malformed flag keeps the visit and reads as not typed.
struct BrowserHistoryJSONEntry: Codable, Sendable {
    var url: String
    var title: String
    var visitedAt: Date
    var typed: Bool

    private enum CodingKeys: String, CodingKey {
        case url, title, visitedAt, typed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        visitedAt = try c.decode(Date.self, forKey: .visitedAt)
        typed = ((try? c.decodeIfPresent(Bool.self, forKey: .typed)) ?? nil) == true
    }

    var importValue: BrowserHistoryImport {
        BrowserHistoryImport(url: url, title: title, visitedAt: visitedAt, kind: typed ? .typed : .link)
    }
}
