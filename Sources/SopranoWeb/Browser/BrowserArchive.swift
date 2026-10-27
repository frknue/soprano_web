import Foundation

// MARK: - Entries

/// Why a tab went into the Archive.
enum BrowserArchiveReason: String, Codable, CaseIterable, Sendable {
    /// ⌘W on a Today tab, or ⇧⌘K (Archive Today Tabs).
    case manual
    /// Idle past its profile's `archiveAfter`.
    case auto
    /// Brought in by an importer (Arc's `StorableArchiveItems.json`).
    case imported
}

/// One archived tab: what the sidebar's Archive section lists and restores.
struct BrowserArchiveEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var url: String
    var title: String
    /// The Space it was archived from; nil when unknown (an import). A
    /// restore falls back to the profile's first Space.
    var spaceID: UUID?
    var profileID: UUID
    var archivedAt: Date
    var reason: BrowserArchiveReason
    /// The favicon cache key (`BrowserFaviconSelection.key(for:)`) when
    /// archived; the row falls back to the address's host.
    var faviconKey: String?

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        spaceID: UUID?,
        profileID: UUID,
        archivedAt: Date,
        reason: BrowserArchiveReason,
        faviconKey: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.spaceID = spaceID
        self.profileID = profileID
        self.archivedAt = archivedAt
        self.reason = reason
        self.faviconKey = faviconKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, spaceID, profileID, archivedAt, reason, faviconKey
    }

    /// An entry needs an id, a non-empty address, a profile and a date; a
    /// missing title is empty, an unknown reason `manual`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "empty address")
        }
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        spaceID = (try? c.decodeIfPresent(UUID.self, forKey: .spaceID)) ?? nil
        profileID = try c.decode(UUID.self, forKey: .profileID)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil)
            .flatMap(BrowserArchiveReason.init(rawValue:)) ?? .manual
        faviconKey = (try? c.decodeIfPresent(String.self, forKey: .faviconKey)) ?? nil
    }

    /// The address's host ("" without one).
    var host: String {
        URL(string: url)?.host ?? ""
    }

    /// The title, else the host, else the address.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? url : host
    }

    /// Whether a tab at `url` can be archived: web and file pages (never
    /// the start page, `about:` or `data:`).
    static func isArchivable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}

/// `archive.json`: `{ "version": 1, "entries": [...] }`, newest first.
/// Decoding is tolerant: an entry that does not decode is skipped and a
/// repeated id keeps its first entry.
struct BrowserArchiveFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var entries: [BrowserArchiveEntry]

    init(entries: [BrowserArchiveEntry]) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case version, entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let decoded = (try? c.decodeIfPresent(LossyArray<BrowserArchiveEntry>.self, forKey: .entries))?.elements ?? []
        var seen: Set<UUID> = []
        entries = decoded.filter { seen.insert($0.id).inserted }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(entries, forKey: .entries)
    }
}

// MARK: - Search

/// The Archive's search: every word of the query must occur in the title
/// or the address, ignoring case, diacritics and width ("cafe" finds
/// "Café").
enum BrowserArchiveSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What `matches` searches for an entry: its folded title and address.
    static func key(for entry: BrowserArchiveEntry) -> String {
        fold(entry.title) + "\n" + fold(entry.url)
    }

    /// The query's folded words; empty matches everything.
    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(key: String, words: [String]) -> Bool {
        words.allSatisfy { key.contains($0) }
    }
}

// MARK: - Auto-archive policy

/// Why a tab is not archived whatever its idle time.
enum BrowserArchiveExemption: String, Equatable, Sendable {
    /// A private or pop-up window's tab (no Spaces): private windows never
    /// archive.
    case noSpace
    /// A pinned or favorite tab: those unload to their pin instead.
    case linked
    /// The start page or a page with no web address: nothing to keep.
    case startPage
    /// The selected tab of its window.
    case selected
    /// A tab with a pop-up window open.
    case popup
    case playingAudio
    /// Camera, microphone or screen capture.
    case capturing
    /// An open dialog, sheet, sign-in or permission prompt.
    case prompt
}

/// What the archive policy reads from one tab.
struct BrowserArchiveCandidate: Equatable, Sendable {
    /// A normal window's tab in a Space.
    var inSpace = true
    /// A Today tab (not pinned, not a favorite).
    var isToday = true
    /// The start page, or an address `BrowserArchiveEntry.isArchivable`
    /// refuses.
    var isStartPage = false
    /// What the sleep policy reads (selection, audio, capture, prompts,
    /// pop-ups and `lastActive`, the last time the tab was selected or
    /// left).
    var activity: BrowserTabSleepCandidate
}

/// Which Today tabs archive themselves: idle at least their profile's
/// `archiveAfter` and not exempt. It reuses the sleep policy's selection,
/// pop-up, audio, capture and prompt exemptions; a tab that is asleep,
/// still restoring, loading, kept awake or has unsaved input does archive
/// (any page with a `beforeunload` listener counts as unsaved, so honoring
/// that would keep most tabs forever).
enum BrowserArchivePolicy {
    static func exemption(for candidate: BrowserArchiveCandidate) -> BrowserArchiveExemption? {
        if !candidate.inSpace { return .noSpace }
        if !candidate.isToday { return .linked }
        if candidate.isStartPage { return .startPage }
        let activity = candidate.activity
        if activity.isSelected { return .selected }
        if activity.isPopup { return .popup }
        if activity.isPlayingAudio { return .playingAudio }
        if activity.isCapturing { return .capturing }
        if activity.hasOpenPrompt { return .prompt }
        return nil
    }

    /// How long a Today tab of a profile with `archiveAfter` must be idle;
    /// nil never.
    static func idleThreshold(_ archiveAfter: BrowserArchiveAfter) -> TimeInterval? {
        archiveAfter.interval
    }

    static func shouldArchive(
        _ candidate: BrowserArchiveCandidate,
        now: Date,
        archiveAfter: BrowserArchiveAfter
    ) -> Bool {
        guard let threshold = idleThreshold(archiveAfter), exemption(for: candidate) == nil else { return false }
        return now.timeIntervalSince(candidate.activity.lastActive) >= threshold
    }
}
