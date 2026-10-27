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

    /// Archives one tab (`archive(_:)` with one entry). Nil for an address
    /// that can't be archived.
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
        archive([BrowserArchiveEntry(
            url: address,
            title: title,
            spaceID: spaceID,
            profileID: profileID,
            archivedAt: date,
            reason: reason,
            faviconKey: faviconKey
        )]).first
    }

    /// Archives many tabs with one write and one `changes` (⇧⌘K, the idle
    /// pass). An entry of the same profile and address already in the
    /// Archive (or earlier in the batch) is replaced, so a page shows once,
    /// at its newest time. Addresses that can't be archived are skipped.
    /// The search index changes only for the entries added and replaced.
    /// Returns the entries added.
    @discardableResult
    func archive(_ newEntries: [BrowserArchiveEntry]) -> [BrowserArchiveEntry] {
        func key(_ entry: BrowserArchiveEntry) -> String { "\(entry.profileID.uuidString)|\(entry.url)" }
        var seen: Set<String> = []
        let batch = Self.sorted(newEntries.filter { BrowserArchiveEntry.isArchivable(URL(string: $0.url)) })
            .filter { seen.insert(key($0)).inserted }
        guard let oldest = batch.last else { return [] }
        var kept: [BrowserArchiveEntry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            if seen.contains(key(entry)) {
                searchKeys[entry.id] = nil
            } else {
                kept.append(entry)
            }
        }
        for entry in batch {
            searchKeys[entry.id] = BrowserArchiveSearch.key(for: entry)
        }
        // Usually the batch is newer than everything; merge only when not.
        entries = kept.first.map { oldest.archivedAt >= $0.archivedAt } ?? true
            ? batch + kept
            : Self.sorted(batch + kept)
        save()
        return batch
    }

    /// The profile's entry for `address`, removed (⇧⌘T brought the tab
    /// back).
    @discardableResult
    func removeEntry(url address: String, profileID: UUID) -> BrowserArchiveEntry? {
        guard let index = entries.firstIndex(where: { $0.profileID == profileID && $0.url == address }) else {
            return nil
        }
        let removed = entries.remove(at: index)
        searchKeys[removed.id] = nil
        save()
        return removed
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
        searchKeys[id] = nil
        save()
        return removed
    }

    /// Every entry of a profile (the profile is deleted).
    func removeEntries(ofProfile profileID: UUID) {
        removeEntries { $0.profileID == profileID }
    }

    /// The profile's entries archived within `range` (Clear Browsing Data
    /// ▸ History for that profile).
    func removeEntries(ofProfile profileID: UUID, archivedIn range: ClosedRange<Date>) {
        removeEntries { $0.profileID == profileID && range.contains($0.archivedAt) }
    }

    /// Entries of a Space that now has another profile (Spaces separated
    /// from a shared profile) move to it: `profileOfSpace` maps a Space id
    /// to its profile. One write; nothing happens when every entry is in
    /// its Space's profile already. Returns how many moved.
    @discardableResult
    func moveEntries(toProfileOfSpace profileOfSpace: [UUID: UUID]) -> Int {
        var moved = 0
        for index in entries.indices {
            guard let spaceID = entries[index].spaceID, let profileID = profileOfSpace[spaceID],
                  entries[index].profileID != profileID
            else { continue }
            entries[index].profileID = profileID
            moved += 1
        }
        guard moved > 0 else { return 0 }
        save()
        return moved
    }

    private func removeEntries(where shouldRemove: (BrowserArchiveEntry) -> Bool) {
        let count = entries.count
        entries.removeAll { entry in
            guard shouldRemove(entry) else { return false }
            searchKeys[entry.id] = nil
            return true
        }
        guard entries.count != count else { return }
        save()
    }

    // MARK: Saving

    /// Re-sorts and re-indexes everything (the importers' insert), then
    /// saves.
    private func commit() {
        entries = Self.sorted(entries)
        rebuildIndex()
        save()
    }

    /// One write of `archive.json` and one `changes` per change.
    private func save() {
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
