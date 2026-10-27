import Foundation

// MARK: - Space

/// What a Space shows before its name: nothing, an emoji or an SF Symbol.
enum BrowserSpaceIcon: Equatable, Sendable {
    case none
    case emoji(String)
    case symbol(String)
}

/// One Space: a name, an icon, a color mark and its pinned tree, with a
/// profile of its own (`profileID`, never shared with another Space) that
/// holds its cookies, website data, History, site decisions, Archive and
/// Favorites. The profile is the Space's data container, never shown.
struct BrowserSpace: Identifiable, Equatable, Sendable {
    static let defaultName = "Space"

    var id: UUID
    var name: String
    var icon: BrowserSpaceIcon
    /// A mark only (a dot by the name); the window is never tinted.
    var color: BrowserProfileColor
    var profileID: UUID
    var pinned: BrowserPinTree
    /// Where an import made it (e.g. Arc's Space id), so a re-import skips it.
    var importedFrom: String?

    init(
        id: UUID = UUID(),
        name: String,
        icon: BrowserSpaceIcon = .none,
        color: BrowserProfileColor,
        profileID: UUID,
        pinned: BrowserPinTree = BrowserPinTree(),
        importedFrom: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.profileID = profileID
        self.pinned = pinned
        self.importedFrom = importedFrom
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }
}

// MARK: - Favorites

/// A Space's favorites, kept by its profile: an ordered list of at most
/// `limit` pins. Operations are pure; one that can't
/// apply (the 13th favorite, a repeated id, an unknown id) returns false or
/// nil and changes nothing.
struct BrowserFavorites: Equatable, Sendable {
    static let limit = 12

    var profileID: UUID
    private(set) var items: [BrowserPin]

    /// Keeps the first `limit` items, once per id.
    init(profileID: UUID, items: [BrowserPin] = []) {
        self.profileID = profileID
        var seen: Set<UUID> = []
        self.items = Array(items.filter { seen.insert($0.id).inserted }.prefix(Self.limit))
    }

    var isEmpty: Bool { items.isEmpty }
    var isFull: Bool { items.count >= Self.limit }

    func item(id: UUID) -> BrowserPin? {
        items.first { $0.id == id }
    }

    /// Inserts `pin` at `index` (clamped; nil appends).
    @discardableResult
    mutating func add(_ pin: BrowserPin, at index: Int? = nil) -> Bool {
        guard !isFull, item(id: pin.id) == nil else { return false }
        let position = min(max(index ?? items.count, 0), items.count)
        items.insert(pin, at: position)
        return true
    }

    /// Moves `id` before the item now at `index` (the drop gap, counted
    /// before `id` leaves its place; clamped).
    @discardableResult
    mutating func move(_ id: UUID, to index: Int) -> Bool {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return false }
        var target = min(max(index, 0), items.count)
        if source < target {
            target -= 1
        }
        let pin = items.remove(at: source)
        items.insert(pin, at: target)
        return true
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> BrowserPin? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Points favorite `id` at another page (Replace with Current Page);
    /// it keeps its id and place.
    @discardableResult
    mutating func replace(_ id: UUID, url: String, title: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].url = url
        items[index].title = title
        return true
    }
}

// MARK: - Archive timing

/// How long a Today tab may sit unused before it is archived
/// (`BrowserProfile.archiveAfter`: per Space, kept by its profile; Edit
/// Space sets it).
enum BrowserArchiveAfter: String, Codable, CaseIterable, Sendable {
    case never
    case days30
    case days7
    case hours24
    case hours12
    case hours6
    case hour1

    static let `default`: BrowserArchiveAfter = .hours12

    /// The idle time; nil for never.
    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .days30: 30 * 86_400
        case .days7: 7 * 86_400
        case .hours24: 86_400
        case .hours12: 12 * 3_600
        case .hours6: 6 * 3_600
        case .hour1: 3_600
        }
    }

    /// The choice as Settings ▸ Profiles shows it after "Archive Today
    /// tabs after".
    var title: String {
        switch self {
        case .never: "Never"
        case .days30: "30 days"
        case .days7: "7 days"
        case .hours24: "24 hours"
        case .hours12: "12 hours"
        case .hours6: "6 hours"
        case .hour1: "1 hour"
        }
    }
}

// MARK: - List

/// Every Space in display order and every Space's favorites (kept by its
/// profile), with the pure operations `BrowserSpaceStore` applies. Ids
/// stay unique, and so does each Space's profile: `create` refuses a
/// profile another Space has, `isolate` separates Spaces that share one
/// (an older `spaces.json`) and `reconcile(with:)` gives every profile its
/// Space.
struct BrowserSpaceList: Equatable, Sendable {
    /// A Space `isolate` gave a profile of its own: `id` is the Space's id
    /// and its new profile's (named after it, in its color), `from` the
    /// profile it shared (nil when the profile is only missing).
    struct Separation: Equatable, Sendable {
        var spaceID: UUID
        var from: UUID?
    }

    private(set) var spaces: [BrowserSpace]
    /// One entry per profile with favorites, in the order they were made.
    private(set) var favorites: [BrowserFavorites]

    /// Repeated Space ids and repeated profile favorites keep their first.
    init(spaces: [BrowserSpace] = [], favorites: [BrowserFavorites] = []) {
        var seenSpaces: Set<UUID> = []
        self.spaces = spaces.filter { seenSpaces.insert($0.id).inserted }
        var seenProfiles: Set<UUID> = []
        self.favorites = favorites.filter { seenProfiles.insert($0.profileID).inserted }
    }

    // MARK: Lookup

    func space(id: UUID) -> BrowserSpace? {
        spaces.first { $0.id == id }
    }

    /// The Space whose data profile `profileID` holds.
    func space(ofProfile profileID: UUID) -> BrowserSpace? {
        spaces.first { $0.profileID == profileID }
    }

    /// The Space of the Default profile (the default data store): it can't
    /// be deleted.
    var defaultSpace: BrowserSpace? {
        space(ofProfile: BrowserProfile.defaultID)
    }

    func favorites(ofProfile profileID: UUID) -> BrowserFavorites {
        favorites.first { $0.profileID == profileID } ?? BrowserFavorites(profileID: profileID)
    }

    // MARK: Spaces

    /// Appends a Space; an empty name becomes "Space". Refused (nil) when
    /// `id` is taken or another Space has `profileID`.
    @discardableResult
    mutating func create(
        name: String,
        icon: BrowserSpaceIcon = .none,
        color: BrowserProfileColor,
        profileID: UUID,
        pinned: BrowserPinTree = BrowserPinTree(),
        importedFrom: String? = nil,
        id: UUID = UUID()
    ) -> BrowserSpace? {
        guard space(id: id) == nil, space(ofProfile: profileID) == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = BrowserSpace(
            id: id,
            name: trimmed.isEmpty ? BrowserSpace.defaultName : trimmed,
            icon: icon,
            color: color,
            profileID: profileID,
            pinned: pinned,
            importedFrom: importedFrom
        )
        spaces.append(space)
        return space
    }

    /// Gives `profile` a Space named after it, in its color, when it has
    /// none; returns its Space.
    @discardableResult
    mutating func ensureSpace(for profile: BrowserProfile) -> BrowserSpace {
        if let existing = space(ofProfile: profile.id) {
            return existing
        }
        let space = BrowserSpace(name: profile.name, color: profile.color, profileID: profile.id)
        spaces.append(space)
        return space
    }

    /// Every Space gets a profile of its own. A Space whose profile an
    /// earlier Space (in display order) already has moves to a new profile
    /// whose id is the Space's own; so does a Space whose profile is
    /// missing from `known` while its id is that profile's (a separation an
    /// interrupted launch wrote here but not into `profiles.json`). Returns
    /// the separations, in Space order, so the caller makes their
    /// profiles; running it again finds none.
    mutating func isolate(known: Set<UUID>) -> [Separation] {
        var claimed: Set<UUID> = []
        var separations: [Separation] = []
        for index in spaces.indices {
            let space = spaces[index]
            if claimed.contains(space.profileID) {
                // A profile with that id may exist already: a launch that
                // wrote `profiles.json` but not this file.
                spaces[index].profileID = space.id
                separations.append(Separation(spaceID: space.id, from: space.profileID))
            } else if !known.contains(space.profileID), space.profileID == space.id {
                separations.append(Separation(spaceID: space.id, from: nil))
            }
            claimed.insert(spaces[index].profileID)
        }
        return separations
    }

    /// An import takes over Space `id` (an untouched Space: the Default
    /// Space, or one made for a History-only profile) as the source's
    /// Space: name, icon, color, pinned tree and
    /// `importedFrom` become the import's. Refused when the Space was
    /// imported already or holds pins.
    @discardableResult
    mutating func adopt(
        _ id: UUID,
        name: String,
        icon: BrowserSpaceIcon,
        color: BrowserProfileColor,
        pinned: BrowserPinTree,
        importedFrom: String
    ) -> Bool {
        guard let space = space(id: id), space.importedFrom == nil, space.pinned.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return update(id) {
            $0.name = trimmed.isEmpty ? BrowserSpace.defaultName : trimmed
            $0.icon = icon
            $0.color = color
            $0.pinned = pinned
            $0.importedFrom = importedFrom
        }
    }

    /// The Space an import made from `source` (`importedFrom`).
    func space(importedFrom source: String) -> BrowserSpace? {
        spaces.first { $0.importedFrom == source }
    }

    @discardableResult
    mutating func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return update(id) { $0.name = trimmed }
    }

    @discardableResult
    mutating func setIcon(_ id: UUID, _ icon: BrowserSpaceIcon) -> Bool {
        update(id) { $0.icon = icon }
    }

    @discardableResult
    mutating func setColor(_ id: UUID, _ color: BrowserProfileColor) -> Bool {
        update(id) { $0.color = color }
    }

    /// Moves `id` before the Space now at `index` (the drop gap, counted
    /// before it leaves its place; clamped).
    @discardableResult
    mutating func move(_ id: UUID, to index: Int) -> Bool {
        guard let source = spaces.firstIndex(where: { $0.id == id }) else { return false }
        var target = min(max(index, 0), spaces.count)
        if source < target {
            target -= 1
        }
        let space = spaces.remove(at: source)
        spaces.insert(space, at: target)
        return true
    }

    /// A deleted profile's Space and favorites (deleting a Space deletes
    /// its profile: `BrowserWindowManager.deleteSpace`).
    mutating func deleteSpace(ofProfile profileID: UUID) {
        spaces.removeAll { $0.profileID == profileID }
        favorites.removeAll { $0.profileID == profileID }
    }

    /// Every profile in `profiles` gets a Space when it has none; Spaces
    /// and favorites of profiles not in it go. True when anything changed.
    @discardableResult
    mutating func reconcile(with profiles: [BrowserProfile]) -> Bool {
        let before = self
        let ids = Set(profiles.map(\.id))
        spaces.removeAll { !ids.contains($0.profileID) }
        favorites.removeAll { !ids.contains($0.profileID) }
        for profile in profiles {
            ensureSpace(for: profile)
        }
        return self != before
    }

    /// Applies `change` to Space `id`'s pinned tree.
    @discardableResult
    mutating func updatePins(in id: UUID, _ change: (inout BrowserPinTree) -> Bool) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        return change(&spaces[index].pinned)
    }

    /// Applies `change` to the profile's favorites (made when missing).
    @discardableResult
    mutating func updateFavorites(ofProfile profileID: UUID, _ change: (inout BrowserFavorites) -> Bool) -> Bool {
        var list = favorites(ofProfile: profileID)
        guard change(&list) else { return false }
        if let index = favorites.firstIndex(where: { $0.profileID == profileID }) {
            favorites[index] = list
        } else {
            favorites.append(list)
        }
        return true
    }

    private mutating func update(_ id: UUID, _ change: (inout BrowserSpace) -> Void) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        change(&spaces[index])
        return true
    }
}

// MARK: - File

/// `spaces.json`:
/// `{ "version": 1, "spaces": [space], "favorites": [{ "profileID", "items": [pin] }] }`.
/// A Space is `{ "id", "name", "icon", "color", "profileID", "pinned":
/// { folder }, "importedFrom" }` with `icon` absent (none) or
/// `{ "type": "emoji" | "symbol", "value" }`; folders and pins are coded as
/// in `BrowserPinNode`. Decoding is tolerant: a Space without an id or a
/// profile is skipped, a missing name becomes "Space", an unknown color
/// blue, an unreadable icon none, unreadable pins are skipped and
/// repeated ids dropped.
struct BrowserSpacesFile: Codable, Equatable {
    static let currentVersion = 1

    var list: BrowserSpaceList

    init(list: BrowserSpaceList) {
        self.list = list
    }

    private enum CodingKeys: String, CodingKey {
        case version, spaces, favorites
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let spaces = (try? c.decodeIfPresent(LossyArray<BrowserSpace>.self, forKey: .spaces))?.elements ?? []
        let favorites = (try? c.decodeIfPresent(LossyArray<BrowserFavorites>.self, forKey: .favorites))?.elements ?? []
        list = BrowserSpaceList(spaces: spaces, favorites: favorites)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(list.spaces, forKey: .spaces)
        try c.encode(list.favorites.filter { !$0.isEmpty }, forKey: .favorites)
    }
}

extension BrowserSpaceIcon: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = ((try? c.decodeIfPresent(String.self, forKey: .value)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil {
        case "emoji" where !value.isEmpty: self = .emoji(value)
        case "symbol" where !value.isEmpty: self = .symbol(value)
        default: self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .type)
        case let .emoji(value):
            try c.encode("emoji", forKey: .type)
            try c.encode(value, forKey: .value)
        case let .symbol(value):
            try c.encode("symbol", forKey: .type)
            try c.encode(value, forKey: .value)
        }
    }
}

extension BrowserSpace: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, color, profileID, pinned, importedFrom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = (try? c.decodeIfPresent(BrowserPinFolder.self, forKey: .pinned)) ?? nil
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: name.isEmpty ? Self.defaultName : name,
            icon: ((try? c.decodeIfPresent(BrowserSpaceIcon.self, forKey: .icon)) ?? nil) ?? .none,
            color: ((try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil)
                .flatMap(BrowserProfileColor.init(rawValue:)) ?? .blue,
            profileID: try c.decode(UUID.self, forKey: .profileID),
            pinned: root.map(BrowserPinTree.init(root:)) ?? BrowserPinTree(),
            importedFrom: (try? c.decodeIfPresent(String.self, forKey: .importedFrom)) ?? nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if icon != .none {
            try c.encode(icon, forKey: .icon)
        }
        try c.encode(color, forKey: .color)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(pinned.root, forKey: .pinned)
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
    }
}

extension BrowserFavorites: Codable {
    private enum CodingKeys: String, CodingKey {
        case profileID, items
    }

    /// Needs a profile; items that aren't pins are skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nodes = (try? c.decodeIfPresent(LossyArray<BrowserPinNode>.self, forKey: .items))?.elements ?? []
        self.init(profileID: try c.decode(UUID.self, forKey: .profileID), items: nodes.compactMap(\.pin))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(items.map(BrowserPinNode.pin), forKey: .items)
    }
}
