import Foundation

// MARK: - History

struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var url: String
    var title: String
    var visitedAt: Date

    init(id: UUID = UUID(), url: String, title: String, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url : trimmed
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
        self.entries = JSONFile.read([BrowserHistoryEntry].self, at: url) ?? []
        entries.sort { $0.visitedAt > $1.visitedAt }
    }

    func record(url address: String, title: String, at date: Date = Date()) {
        guard let parsed = URL(string: address),
              ["http", "https", "file"].contains(parsed.scheme?.lowercased() ?? "")
        else { return }

        if let first = entries.first,
           first.url == address,
           date.timeIntervalSince(first.visitedAt) < 300
        {
            entries[0].title = title
            entries[0].visitedAt = date
            onChange?()
            persist()
            return
        }

        entries.insert(BrowserHistoryEntry(url: address, title: title, visitedAt: date), at: 0)
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

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
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
        try? JSONFile.write(entries, to: url)
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
        self.bookmarks = JSONFile.read([BrowserBookmark].self, at: url) ?? []
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
        try? JSONFile.write(bookmarks, to: url)
        onChange?()
    }
}

// MARK: - Downloads

enum BrowserDownloadState: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled

    var label: String {
        switch self {
        case .inProgress: "Downloading…"
        case .completed: "Downloaded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
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

    init(
        id: UUID = UUID(),
        url: String,
        filename: String,
        path: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        state: BrowserDownloadState = .inProgress,
        errorMessage: String? = nil,
        fractionCompleted: Double = 0
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
    }
}

@MainActor
final class BrowserDownloadStore {
    private(set) var records: [BrowserDownloadRecord]
    let url: URL
    var onChange: (() -> Void)?

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("downloads.json")) {
        self.url = url
        let saved = JSONFile.read([BrowserDownloadRecord].self, at: url) ?? []
        self.records = saved.filter { $0.state != .inProgress }.sorted { $0.startedAt > $1.startedAt }
    }

    func begin(url address: String, filename: String) -> BrowserDownloadRecord {
        let record = BrowserDownloadRecord(url: address, filename: filename)
        records.insert(record, at: 0)
        onChange?()
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

    func finish(id: UUID, path: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].path = path
        records[index].state = .completed
        records[index].fractionCompleted = 1
        records[index].finishedAt = Date()
        prune()
        onChange?()
        persist()
    }

    func fail(id: UUID, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .failed
        records[index].finishedAt = Date()
        records[index].errorMessage = message
        prune()
        onChange?()
        persist()
    }

    func cancel(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .cancelled
        records[index].finishedAt = Date()
        prune()
        onChange?()
        persist()
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        onChange?()
        persist()
    }

    func clearFinished() {
        records.removeAll { $0.state != .inProgress }
        onChange?()
        persist()
    }

    func matching(_ query: String) -> [BrowserDownloadRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return records }
        return records.filter {
            $0.filename.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }
    }

    private func prune() {
        let finished = records.filter { $0.state != .inProgress }
        guard finished.count > 200 else { return }
        let keep = Set(finished.sorted { $0.startedAt > $1.startedAt }.prefix(200).map(\.id))
        records.removeAll { $0.state != .inProgress && !keep.contains($0.id) }
    }

    private func persist() {
        let finished = records.filter { $0.state != .inProgress }
        try? JSONFile.write(finished, to: url)
    }
}
