import Foundation

// MARK: - History

struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var visitedAt: Date
    /// True when the visit started from the address bar. Nil in entries
    /// written before the flag existed; read as not typed.
    var typed: Bool?

    init(id: UUID = UUID(), url: String, title: String, visitedAt: Date = Date(), typed: Bool? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.typed = typed
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
    }
}

extension BrowserHistoryEntry {
    /// `typed` is optional and lossy: a missing or malformed flag keeps the
    /// visit and reads as not typed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        visitedAt = try c.decode(Date.self, forKey: .visitedAt)
        typed = (try? c.decodeIfPresent(Bool.self, forKey: .typed)) ?? nil
    }
}

@MainActor
final class BrowserHistoryStore {
    private(set) var entries: [BrowserHistoryEntry]
    let url: URL
    let limit: Int
    var onChange: (() -> Void)?

    init(
        url: URL = BrowserFiles.supportDirectory().appendingPathComponent("history.json"),
        limit: Int = 5_000
    ) {
        self.url = url
        self.limit = limit
        self.entries = JSONFile.read(JSONList<BrowserHistoryEntry>.self, at: url)?.entries ?? []
        entries.sort { $0.visitedAt > $1.visitedAt }
    }

    func record(url address: String, title: String, at date: Date = Date(), typed: Bool = false) {
        guard let parsed = URL(string: address),
              ["http", "https", "file"].contains(parsed.scheme?.lowercased() ?? "")
        else { return }

        if let first = entries.first,
           first.url == address,
           date.timeIntervalSince(first.visitedAt) < 300
        {
            entries[0].title = title
            entries[0].visitedAt = date
            if typed { entries[0].typed = true }
            onChange?()
            persist()
            return
        }

        entries.insert(
            BrowserHistoryEntry(url: address, title: title, visitedAt: date, typed: typed ? true : nil),
            at: 0
        )
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        onChange?()
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        onChange?()
        persist()
    }

    /// Removes the visits at or after `date` (Clear Browsing Data).
    func removeEntries(since date: Date) {
        let count = entries.count
        entries.removeAll { $0.visitedAt >= date }
        guard entries.count != count else { return }
        onChange?()
        persist()
    }

    func matching(_ query: String) -> [BrowserHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }
    }

    private func persist() {
        try? JSONFile.write(JSONList(entries), to: url)
    }
}

// MARK: - Bookmarks

struct BrowserBookmark: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var addedAt: Date

    init(id: UUID = UUID(), url: String, title: String, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.addedAt = addedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
    }
}

@MainActor
final class BrowserBookmarkStore {
    private(set) var bookmarks: [BrowserBookmark]
    let url: URL
    var onChange: (() -> Void)?

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("bookmarks.json")) {
        self.url = url
        self.bookmarks = JSONFile.read(JSONList<BrowserBookmark>.self, at: url)?.entries ?? []
        bookmarks.sort { $0.addedAt > $1.addedAt }
    }

    func isBookmarked(_ address: String) -> Bool {
        bookmarks.contains { $0.url == address }
    }

    @discardableResult
    func toggle(url address: String, title: String) -> Bool {
        if let existing = bookmarks.first(where: { $0.url == address }) {
            bookmarks.removeAll { $0.id == existing.id }
            persist()
            return false
        }
        bookmarks.insert(BrowserBookmark(url: address, title: title), at: 0)
        persist()
        return true
    }

    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func matching(_ query: String) -> [BrowserBookmark] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }
    }

    private func persist() {
        try? JSONFile.write(JSONList(bookmarks), to: url)
        onChange?()
    }
}

// MARK: - Downloads

enum BrowserDownloadState: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled
    /// Stopped by quitting (or a crash) while downloading.
    case interrupted

    var label: String {
        switch self {
        case .inProgress: "Downloading…"
        case .completed: "Downloaded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    /// Stopped before finishing: Retry starts it again, Resume continues it
    /// when resume data was kept.
    var isStopped: Bool {
        self == .failed || self == .cancelled || self == .interrupted
    }
}

struct BrowserDownloadRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var filename: String
    var path: String?
    var startedAt: Date
    var finishedAt: Date?
    var state: BrowserDownloadState
    var errorMessage: String?
    /// `WKDownload.progress.fractionCompleted`, kept in memory while active and
    /// recorded as 1 on finish.
    var fractionCompleted: Double
    /// File name of the saved `WKDownload` resume data in the store's
    /// resume-data directory; nil when the download cannot be resumed.
    var resumeDataFile: String?

    init(
        id: UUID = UUID(),
        url: String,
        filename: String,
        path: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        state: BrowserDownloadState = .inProgress,
        errorMessage: String? = nil,
        fractionCompleted: Double = 0,
        resumeDataFile: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.path = path
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.errorMessage = errorMessage
        self.fractionCompleted = fractionCompleted
        self.resumeDataFile = resumeDataFile
    }

    var canResume: Bool {
        state.isStopped && resumeDataFile != nil
    }

    var canRetry: Bool {
        guard state.isStopped, let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

@MainActor
final class BrowserDownloadStore {
    private(set) var records: [BrowserDownloadRecord]
    let url: URL
    /// Holds one `<record id>.resume` file per resumable download.
    let resumeDataDirectory: URL
    var onChange: (() -> Void)?

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("downloads.json")) {
        self.url = url
        let resumeDataDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("DownloadResumeData", isDirectory: true)
        self.resumeDataDirectory = resumeDataDirectory
        let saved = JSONFile.read(JSONList<BrowserDownloadRecord>.self, at: url)?.entries ?? []
        // A record still in progress on disk outlived its app (quit or crash).
        self.records = saved.map { record in
            var record = record
            if record.state == .inProgress {
                record.state = .interrupted
            }
            if let file = record.resumeDataFile,
               !FileManager.default.fileExists(atPath: resumeDataDirectory.appendingPathComponent(file).path)
            {
                record.resumeDataFile = nil
            }
            return record
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func begin(url address: String, filename: String, path: String? = nil) -> BrowserDownloadRecord {
        let record = BrowserDownloadRecord(url: address, filename: filename, path: path)
        records.insert(record, at: 0)
        onChange?()
        persist()
        return record
    }

    func updateProgress(id: UUID, fraction: Double) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].state == .inProgress
        else { return }
        let value = min(1, max(0, fraction))
        guard abs(records[index].fractionCompleted - value) >= 0.005 else { return }
        records[index].fractionCompleted = value
        onChange?()
    }

    /// Sets the destination chosen once the response arrived (Retry reuses
    /// its record and may land on a new file name).
    func setDestination(id: UUID, path: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].path = path
        records[index].filename = URL(fileURLWithPath: path).lastPathComponent
        onChange?()
        persist()
    }

    func finish(id: UUID, path: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].path = path
        records[index].state = .completed
        records[index].fractionCompleted = 1
        records[index].finishedAt = Date()
        records[index].errorMessage = nil
        discardResumeData(at: index)
        prune()
        onChange?()
        persist()
    }

    func fail(id: UUID, message: String, resumeData: Data? = nil) {
        stop(id: id, state: .failed, message: message, resumeData: resumeData)
    }

    func cancel(id: UUID, resumeData: Data? = nil) {
        stop(id: id, state: .cancelled, message: nil, resumeData: resumeData)
    }

    /// Quit stopped the download; it shows as interrupted after relaunch.
    func interrupt(id: UUID, resumeData: Data?) {
        stop(id: id, state: .interrupted, message: nil, resumeData: resumeData)
    }

    /// Keeps resume data that arrives after the record already stopped
    /// (`WKDownload.cancel` reports it asynchronously).
    func attachResumeData(id: UUID, data: Data) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              records[index].state.isStopped
        else { return }
        saveResumeData(data, at: index)
        onChange?()
        persist()
    }

    /// The saved resume data of a stopped download.
    func resumeData(id: UUID) -> Data? {
        guard let record = records.first(where: { $0.id == id }),
              record.canResume,
              let file = record.resumeDataFile
        else { return nil }
        return try? Data(contentsOf: resumeDataDirectory.appendingPathComponent(file))
    }

    /// Resume or Retry restarted the record. The resume data is consumed:
    /// WebKit hands over fresh data if the download stops again.
    func restart(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .inProgress
        records[index].finishedAt = nil
        records[index].errorMessage = nil
        discardResumeData(at: index)
        onChange?()
        persist()
    }

    func remove(id: UUID) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            discardResumeData(at: index)
        }
        records.removeAll { $0.id == id }
        onChange?()
        persist()
    }

    func clearFinished() {
        removeFinished { _ in true }
    }

    /// Removes the list entries of downloads started at or after `date`
    /// (Clear Browsing Data); active downloads stay.
    func removeFinished(startedSince date: Date) {
        removeFinished { $0.startedAt >= date }
    }

    func matching(_ query: String) -> [BrowserDownloadRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return records }
        return records.filter {
            $0.filename.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }
    }

    private func stop(id: UUID, state: BrowserDownloadState, message: String?, resumeData: Data?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        records[index].finishedAt = Date()
        records[index].errorMessage = message
        if let resumeData {
            saveResumeData(resumeData, at: index)
        }
        prune()
        onChange?()
        persist()
    }

    private func removeFinished(where shouldRemove: (BrowserDownloadRecord) -> Bool) {
        let removed = records.indices.filter {
            records[$0].state != .inProgress && shouldRemove(records[$0])
        }
        guard !removed.isEmpty else { return }
        for index in removed {
            discardResumeData(at: index)
        }
        let ids = Set(removed.map { records[$0].id })
        records.removeAll { ids.contains($0.id) }
        onChange?()
        persist()
    }

    private func saveResumeData(_ data: Data, at index: Int) {
        let file = "\(records[index].id.uuidString).resume"
        do {
            try FileManager.default.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try data.write(to: resumeDataDirectory.appendingPathComponent(file), options: .atomic)
            records[index].resumeDataFile = file
        } catch {
            records[index].resumeDataFile = nil
        }
    }

    private func discardResumeData(at index: Int) {
        guard let file = records[index].resumeDataFile else { return }
        try? FileManager.default.removeItem(at: resumeDataDirectory.appendingPathComponent(file))
        records[index].resumeDataFile = nil
    }

    private func prune() {
        let finished = records.filter { $0.state != .inProgress }
        guard finished.count > 200 else { return }
        let keep = Set(finished.sorted { $0.startedAt > $1.startedAt }.prefix(200).map(\.id))
        for index in records.indices where records[index].state != .inProgress && !keep.contains(records[index].id) {
            discardResumeData(at: index)
        }
        records.removeAll { $0.state != .inProgress && !keep.contains($0.id) }
    }

    private func persist() {
        try? JSONFile.write(JSONList(records), to: url)
    }
}
