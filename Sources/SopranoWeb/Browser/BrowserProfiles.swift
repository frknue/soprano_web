import AppKit

/// A Space's color mark: one Folio token, so the mark follows the theme.
enum BrowserProfileColor: String, Codable, CaseIterable, Sendable {
    case blue
    case cyan
    case green
    case yellow
    case red
    case gray

    var name: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    func color(in colors: ThemeColors) -> NSColor {
        switch self {
        case .blue: colors.blue
        case .cyan: colors.cyan
        case .green: colors.success
        case .yellow: colors.yellow
        case .red: colors.danger
        case .gray: colors.gray
        }
    }
}

/// One Space's data container, never shown as such: every Space has a
/// profile of its own (`BrowserSpace.profileID`), whose website data,
/// History, site decisions, Archive, Favorites and archive time are the
/// Space's. Its name and color follow the Space. Downloads, favicons,
/// settings and Recently Closed are shared.
struct BrowserProfile: Codable, Equatable, Identifiable, Sendable {
    /// The Default profile's fixed id. It keeps `WKWebsiteDataStore.default()`
    /// and the files in the support folder itself.
    static let defaultID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let defaultName = "Default"
    /// Every other profile's folder is `<support>/Profiles/<id>/`.
    static let folderName = "Profiles"

    var id: UUID
    var name: String
    var color: BrowserProfileColor
    /// When the profile's Today tabs archive themselves.
    var archiveAfter: BrowserArchiveAfter
    /// Where an import made it (`arc:Profile 3`), so a re-import maps the
    /// source profile to it instead of making another.
    var importedFrom: String?

    init(
        id: UUID = UUID(),
        name: String,
        color: BrowserProfileColor,
        archiveAfter: BrowserArchiveAfter = .default,
        importedFrom: String? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.archiveAfter = archiveAfter
        self.importedFrom = importedFrom
    }

    static var defaultProfile: BrowserProfile {
        BrowserProfile(id: defaultID, name: defaultName, color: .blue)
    }

    var isDefault: Bool { id == Self.defaultID }

    /// Where the profile's `History.sqlite` and `site-permissions.json`
    /// live: the support folder for Default, else its own folder.
    func directory(in support: URL) -> URL {
        isDefault
            ? support
            : support
                .appendingPathComponent(Self.folderName, isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The identifier of the profile's `WKWebsiteDataStore(forIdentifier:)`;
    /// nil for Default, which uses `WKWebsiteDataStore.default()`.
    var dataStoreIdentifier: UUID? {
        isDefault ? nil : id
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, archiveAfter, importedFrom
    }

    /// An entry needs an id; a missing name becomes "Profile", an unknown
    /// color blue, a missing or unknown archive time `.default`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? (id == Self.defaultID ? Self.defaultName : "Profile") : name
        color = ((try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil)
            .flatMap(BrowserProfileColor.init(rawValue:)) ?? .blue
        archiveAfter = ((try? c.decodeIfPresent(String.self, forKey: .archiveAfter)) ?? nil)
            .flatMap(BrowserArchiveAfter.init(rawValue:)) ?? .default
        importedFrom = (try? c.decodeIfPresent(String.self, forKey: .importedFrom)) ?? nil
    }
}

/// `profiles.json`: `{ "version": 1, "profiles": [{id, name, color, archiveAfter, importedFrom?}] }`.
/// Decoding is tolerant: an entry that does not decode is skipped, a
/// repeated id keeps its first entry, and the Default profile is always
/// there, first.
struct BrowserProfileList: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    private(set) var profiles: [BrowserProfile]

    init(_ profiles: [BrowserProfile] = []) {
        self.profiles = Self.normalized(profiles)
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let decoded = (try? c.decodeIfPresent(LossyArray<BrowserProfile>.self, forKey: .profiles))?.elements ?? []
        profiles = Self.normalized(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(profiles, forKey: .profiles)
    }

    /// Default first (added when missing), then the others in file order,
    /// once per id.
    private static func normalized(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        var seen: Set<UUID> = []
        let unique = profiles.filter { seen.insert($0.id).inserted }
        let defaultProfile = unique.first(where: \.isDefault) ?? .defaultProfile
        return [defaultProfile] + unique.filter { !$0.isDefault }
    }

    func profile(id: UUID) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    /// `id` while that profile exists, else Default (a deleted Space's
    /// window or closed tab opens in the Default Space).
    func resolvedID(_ id: UUID) -> UUID {
        profile(id: id) == nil ? BrowserProfile.defaultID : id
    }

    /// Appends `profile`; refused when its id is taken.
    @discardableResult
    mutating func add(_ profile: BrowserProfile) -> Bool {
        guard self.profile(id: profile.id) == nil else { return false }
        profiles.append(profile)
        return true
    }

    /// The profile an import made from `source` (`importedFrom`).
    func profile(importedFrom source: String) -> BrowserProfile? {
        profiles.first { $0.importedFrom == source }
    }

    /// Each profile takes its Space's name and color. True when anything
    /// changed.
    @discardableResult
    mutating func follow(_ spaces: [BrowserSpace]) -> Bool {
        var changed = false
        for space in spaces {
            guard let index = profiles.firstIndex(where: { $0.id == space.profileID }) else { continue }
            if profiles[index].name != space.displayName {
                profiles[index].name = space.displayName
                changed = true
            }
            if profiles[index].color != space.color {
                profiles[index].color = space.color
                changed = true
            }
        }
        return changed
    }

    mutating func setArchiveAfter(id: UUID, _ archiveAfter: BrowserArchiveAfter) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].archiveAfter = archiveAfter
    }

    /// Removes a profile; Default stays.
    mutating func remove(id: UUID) {
        guard id != BrowserProfile.defaultID else { return }
        profiles.removeAll { $0.id == id }
    }
}

/// The profiles in `profiles.json` (support folder). Every change is
/// written at once and announced on `changes`.
@MainActor
final class BrowserProfileStore {
    let url: URL
    let changes = BrowserObservers<Void>()
    private(set) var list: BrowserProfileList

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("profiles.json")) {
        self.url = url
        list = JSONFile.read(BrowserProfileList.self, at: url) ?? BrowserProfileList()
    }

    var profiles: [BrowserProfile] { list.profiles }

    func profile(id: UUID) -> BrowserProfile? { list.profile(id: id) }
    func profile(importedFrom source: String) -> BrowserProfile? { list.profile(importedFrom: source) }
    func resolvedID(_ id: UUID) -> UUID { list.resolvedID(id) }

    /// A new Space's profile (`BrowserSpaceStore.createSpace`, a
    /// separated Space's); refused when its id is taken.
    @discardableResult
    func add(_ profile: BrowserProfile) -> Bool {
        guard list.add(profile) else { return false }
        persist()
        return true
    }

    /// Names and colors follow the Spaces (a Space renamed or recolored).
    func follow(_ spaces: [BrowserSpace]) {
        guard list.follow(spaces) else { return }
        persist()
    }

    /// Edit Space ▸ "Archive Today tabs after", on the Space's profile.
    func setArchiveAfter(id: UUID, _ archiveAfter: BrowserArchiveAfter) {
        guard list.profile(id: id)?.archiveAfter != archiveAfter else { return }
        list.setArchiveAfter(id: id, archiveAfter)
        persist()
    }

    /// Takes the profile out of the list; `BrowserWindowManager.deleteSpace`
    /// removes its Space, windows and data.
    func remove(id: UUID) {
        list.remove(id: id)
        persist()
    }

    private func persist() {
        try? JSONFile.write(list, to: url)
        changes.notify()
    }
}

/// What a window shows of itself next to its tabs: a normal window's
/// current Space (its emoji, name and color mark) when more than one Space
/// exists, "Private" for a private window ("Private · Work" with the Space
/// it was opened over, when there are several); nothing otherwise.
struct BrowserWindowMark: Equatable, Sendable {
    var isPrivate: Bool
    /// The Space's name; nil without one (or while only one Space exists).
    var spaceName: String?
    /// The color dot: the Space's mark.
    var color: BrowserProfileColor?
    var spaceIcon: BrowserSpaceIcon = .none

    /// `space`: the window's Space (a private window's: the one it was
    /// opened over), nil while only one exists.
    init(kind: BrowserWindowKind, space: BrowserSpace?) {
        isPrivate = kind.isPrivate
        spaceName = space?.displayName
        color = space?.color
        spaceIcon = space?.icon ?? .none
    }

    /// The mark's words; nil when there is nothing to show.
    var text: String? {
        let name = spaceName.map { name in
            if case let .emoji(emoji) = spaceIcon {
                return "\(emoji) \(name)"
            }
            return name
        }
        switch (isPrivate, name) {
        case (true, let name?): return "Private · \(name)"
        case (true, nil): return "Private"
        case (false, let name): return name
        }
    }

    var toolTip: String? {
        var parts: [String] = []
        if let spaceName {
            parts.append("Space: \(spaceName)")
        }
        if isPrivate {
            parts.append("Private window: no history, and cookies and site data go when it closes")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
