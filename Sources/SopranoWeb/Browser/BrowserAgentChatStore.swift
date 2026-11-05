import Foundation

/// One Agent chat in the list: its title (the first line of its first
/// message, or what the user renamed it to), when it started and last
/// changed, and whether it is pinned. The conversation itself is omp's
/// session file in the chat's folder (`BrowserAgentChatStore.directory`).
struct BrowserAgentChatRecord: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var pinned: Bool

    init(id: UUID = UUID(), title: String, created: Date, updated: Date? = nil, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.created = created
        self.updated = updated ?? created
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, created, updated, pinned
    }

    /// Missing or mistyped fields take their defaults; only a chat without
    /// an id fails (and the list skips it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        let created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? nil
        let updated = (try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil
        self.created = created ?? updated ?? .distantPast
        self.updated = updated ?? self.created
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
    }
}

/// Every Agent chat: the list in `<support>/agent-chats.json`
/// (`{"version": 1, "entries": [...]}`, newest change first), saved after
/// each change and announced on `changes`, and one folder per chat in
/// `<support>/Agent Chats/<id>/` where omp keeps the chat's session
/// (`--session-dir`). A chat that does not decode is skipped; an
/// unreadable list is kept as `agent-chats.json.corrupt` and starts empty.
/// Deleting a chat moves its folder to the Trash.
@MainActor
final class BrowserAgentChatStore {
    let url: URL
    let folder: URL
    let changes = BrowserObservers<Void>()
    /// Newest change first.
    private(set) var records: [BrowserAgentChatRecord]
    /// Where a deleted chat's folder goes: the Trash (tests remove it).
    var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    var corruptURL: URL { url.appendingPathExtension("corrupt") }

    nonisolated static let longestTitle = 80

    init(supportDirectory: URL) {
        url = supportDirectory.appendingPathComponent("agent-chats.json")
        folder = supportDirectory.appendingPathComponent("Agent Chats", isDirectory: true)
        if let file = JSONFile.read(JSONList<BrowserAgentChatRecord>.self, at: url) {
            var seen = Set<UUID>()
            records = file.entries.filter { seen.insert($0.id).inserted }.sorted(by: Self.newestFirst)
        } else {
            records = []
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: corruptURL)
                try? fileManager.copyItem(at: url, to: corruptURL)
                try? JSONFile.write(JSONList<BrowserAgentChatRecord>([]), to: url)
            }
        }
    }

    func record(_ id: UUID) -> BrowserAgentChatRecord? {
        records.first { $0.id == id }
    }

    /// The chat's folder, omp's `--session-dir`.
    func directory(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The chat's session file, once omp wrote one (after its first answer).
    func sessionFile(for id: UUID) -> URL? {
        BrowserAgentSessionFile.latest(in: directory(for: id))
    }

    /// A new chat for its first message.
    @discardableResult
    func create(firstMessage: String, at date: Date = Date()) -> BrowserAgentChatRecord {
        let record = BrowserAgentChatRecord(title: Self.title(for: firstMessage), created: date)
        records.insert(record, at: 0)
        persist()
        return record
    }

    /// The chat changed (a message went out, a run ended): first in the list.
    func touch(_ id: UUID, at date: Date = Date()) {
        update(id) { $0.updated = max($0.updated, date) }
    }

    /// False for an empty title or an unknown chat.
    @discardableResult
    func rename(_ id: UUID, to title: String) -> Bool {
        let cleaned = Self.title(for: title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record(id) != nil else { return false }
        update(id) { $0.title = cleaned }
        return true
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
    }

    /// Takes the chat off the list and, unless `keepingFolder` (omp may
    /// still write it: `discardFolder` once it ended), moves its folder to
    /// the Trash; the folder stays when that fails.
    @discardableResult
    func delete(_ id: UUID, keepingFolder: Bool = false) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records.remove(at: index)
        persist()
        if !keepingFolder {
            discardFolder(of: id)
        }
        return true
    }

    /// Moves a deleted chat's folder to the Trash.
    func discardFolder(of id: UUID) {
        let directory = directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? discard(directory)
        }
    }

    /// The first non-empty line, trimmed and cut to `longestTitle`.
    static func title(for message: String) -> String {
        let line = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return "New chat" }
        return line.count > longestTitle ? String(line.prefix(longestTitle - 1)) + "…" : line
    }

    private func update(_ id: UUID, _ change: (inout BrowserAgentChatRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record)
        guard record != records[index] else { return }
        records[index] = record
        records.sort(by: Self.newestFirst)
        persist()
    }

    private static func newestFirst(_ a: BrowserAgentChatRecord, _ b: BrowserAgentChatRecord) -> Bool {
        a.updated != b.updated ? a.updated > b.updated : a.created > b.created
    }

    private func persist() {
        try? JSONFile.write(JSONList(records), to: url)
        changes.notify()
    }
}

/// Chats as the Chats menu and the chats page list them: Pinned first,
/// then by their last change: Today, Yesterday, Previous 7 Days, Older.
/// Groups keep the order of `records` and leave out empty ones.
enum BrowserAgentChatGroups {
    struct Group: Equatable {
        var title: String
        var records: [BrowserAgentChatRecord]
    }

    static func groups(
        _ records: [BrowserAgentChatRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        let titles = ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Older"]
        var buckets = Array(repeating: [BrowserAgentChatRecord](), count: titles.count)
        let today = calendar.startOfDay(for: now)
        for record in records {
            let index: Int
            if record.pinned {
                index = 0
            } else {
                let day = calendar.startOfDay(for: record.updated)
                let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
                index = days <= 0 ? 1 : days == 1 ? 2 : days <= 7 ? 3 : 4
            }
            buckets[index].append(record)
        }
        return zip(titles, buckets).compactMap { $1.isEmpty ? nil : Group(title: $0, records: $1) }
    }
}
