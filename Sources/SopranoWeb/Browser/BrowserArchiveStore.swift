import Foundation

/// The Archive: every archived tab of every profile, newest first, saved to
/// `archive.json` (`BrowserArchiveFile`) after each change and announced on
/// `changes`. An unreadable file is kept as `archive.json.corrupt` and the
/// Archive starts empty. Searching reads an in-memory index of folded
/// titles and addresses. Private windows never call it.
@MainActor
final class BrowserArchiveStore {
    let url: URL
    let changes = BrowserObservers<Void>()
    /// Newest first.
    private(set) var entries: [BrowserArchiveEntry]
    /// `BrowserArchiveSearch.key(for:)` of every entry, by id.
    private var searchKeys: [UUID: String] = [:]

    var corruptURL: URL { url.appendingPathExtension("corrupt") }

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("archive.json")) {
        self.url = url
        let fileManager = FileManager.default
        if let file = JSONFile.read(BrowserArchiveFile.self, at: url) {
            entries = Self.sorted(file.entries)
        } else {
            entries = []
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: corruptURL)
                try? fileManager.copyItem(at: url, to: corruptURL)
                try? JSONFile.write(BrowserArchiveFile(entries: []), to: url)
            }
        }
        rebuildIndex()
    }

    func entry(id: UUID) -> BrowserArchiveEntry? {
        entries.first { $0.id == id }
    }

    /// The profile's entries (all its Spaces), newest first.
    func entries(ofProfile profileID: UUID) -> [BrowserArchiveEntry] {
        entries.filter { $0.profileID == profileID }
    }

    /// The profile's entries whose title or address holds every word of
    /// `query` (case and diacritics ignored), newest first; all of them for
    /// an empty query.
    func search(_ query: String, inProfile profileID: UUID) -> [BrowserArchiveEntry] {
        let words = BrowserArchiveSearch.words(query)
        return entries.filter { entry in
            entry.profileID == profileID
                && (words.isEmpty || BrowserArchiveSearch.matches(key: searchKeys[entry.id] ?? "", words: words))
        }
    }

    // MARK: Changes

    /// Archives one tab. An entry of the same profile with the same address
    /// is replaced, so the page shows once, at its newest time. Nil for an
    /// address that can't be archived.
    @discardableResult
    func archive(
        url address: String,
        title: String,
        spaceID: UUID?,
        profileID: UUID,
        at date: Date,
        reason: BrowserArchiveReason,
        faviconKey: String? = nil
    ) -> BrowserArchiveEntry? {
        guard BrowserArchiveEntry.isArchivable(URL(string: address)) else { return nil }
        let entry = BrowserArchiveEntry(
            url: address,
            title: title,
            spaceID: spaceID,
            profileID: profileID,
            archivedAt: date,
            reason: reason,
            faviconKey: faviconKey
        )
        entries.removeAll { $0.profileID == profileID && $0.url == address }
        entries.insert(entry, at: 0)
        commit()
        return entry
    }

    /// The importers' entry point: adds `entries` with `reason` (ids
    /// already in the Archive, and repeats among them, are skipped).
    /// Returns how many were added.
    @discardableResult
    func insert(_ newEntries: [BrowserArchiveEntry], reason: BrowserArchiveReason) -> Int {
        var known = Set(entries.map(\.id))
        let added = newEntries.compactMap { entry -> BrowserArchiveEntry? in
            guard known.insert(entry.id).inserted, !entry.url.isEmpty else { return nil }
            var entry = entry
            entry.reason = reason
            return entry
        }
        guard !added.isEmpty else { return 0 }
        entries += added
        commit()
        return added.count
    }

    /// Removes one entry (Delete, or a restore); returns it.
    @discardableResult
    func remove(id: UUID) -> BrowserArchiveEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: index)
        commit()
        return removed
    }

    /// Every entry of a profile (the profile is deleted).
    func removeEntries(ofProfile profileID: UUID) {
        let count = entries.count
        entries.removeAll { $0.profileID == profileID }
        guard entries.count != count else { return }
        commit()
    }

    /// The profile's entries archived within `range` (Clear Browsing Data
    /// ▸ History for that profile).
    func removeEntries(ofProfile profileID: UUID, archivedIn range: ClosedRange<Date>) {
        let count = entries.count
        entries.removeAll { $0.profileID == profileID && range.contains($0.archivedAt) }
        guard entries.count != count else { return }
        commit()
    }

    // MARK: Saving

    private func commit() {
        entries = Self.sorted(entries)
        rebuildIndex()
        try? JSONFile.write(BrowserArchiveFile(entries: entries), to: url)
        changes.notify()
    }

    private func rebuildIndex() {
        searchKeys = Dictionary(
            entries.map { ($0.id, BrowserArchiveSearch.key(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Newest first; entries of the same time keep their order.
    private static func sorted(_ entries: [BrowserArchiveEntry]) -> [BrowserArchiveEntry] {
        entries.enumerated()
            .sorted { $0.element.archivedAt != $1.element.archivedAt
                ? $0.element.archivedAt > $1.element.archivedAt
                : $0.offset < $1.offset }
            .map(\.element)
    }
}
