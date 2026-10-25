import AppKit

/// A profile's color: one Folio token, so the mark follows the theme.
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

/// One profile (Safari's model): a window belongs to one profile, and its
/// tabs use the profile's website data, history and site decisions. Each
/// profile has one or more Spaces (`BrowserSpaceStore`) and its own
/// favorites; downloads, favicons, settings and Recently Closed are shared.
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

    init(
        id: UUID = UUID(),
        name: String,
        color: BrowserProfileColor,
        archiveAfter: BrowserArchiveAfter = .default
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.archiveAfter = archiveAfter
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
        case id, name, color, archiveAfter
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
    }
}

/// `profiles.json`: `{ "version": 1, "profiles": [{id, name, color, archiveAfter}] }`.
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

    /// The profile named `name`, ignoring case and surrounding spaces.
    func profile(named name: String) -> BrowserProfile? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.first { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
    }

    /// `id` while that profile exists, else Default (a deleted profile's
    /// window or closed tab opens in Default).
    func resolvedID(_ id: UUID) -> UUID {
        profile(id: id) == nil ? BrowserProfile.defaultID : id
    }

    /// `name` trimmed, or "Profile" when empty; a name another profile
    /// already has (ignoring case) gets the next free number ("Work 2").
    func uniqueName(_ name: String, excluding id: UUID? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// The first palette color no profile uses yet, else the one used least.
    var nextColor: BrowserProfileColor {
        let used = profiles.map(\.color)
        return BrowserProfileColor.allCases.min { a, b in
            used.filter { $0 == a }.count < used.filter { $0 == b }.count
        } ?? .blue
    }

    @discardableResult
    mutating func add(name: String, color: BrowserProfileColor? = nil, id: UUID = UUID()) -> BrowserProfile {
        let profile = BrowserProfile(id: id, name: uniqueName(name), color: color ?? nextColor)
        profiles.append(profile)
        return profile
    }

    mutating func rename(id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        profiles[index].name = uniqueName(name, excluding: id)
    }

    mutating func setColor(id: UUID, _ color: BrowserProfileColor) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].color = color
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
    /// Windows show their profile only when there is more than one.
    var hasSeveral: Bool { list.profiles.count > 1 }

    func profile(id: UUID) -> BrowserProfile? { list.profile(id: id) }
    func profile(named name: String) -> BrowserProfile? { list.profile(named: name) }
    func resolvedID(_ id: UUID) -> UUID { list.resolvedID(id) }

    @discardableResult
    func add(name: String, color: BrowserProfileColor? = nil) -> BrowserProfile {
        let profile = list.add(name: name, color: color)
        persist()
        return profile
    }

    func rename(id: UUID, to name: String) {
        list.rename(id: id, to: name)
        persist()
    }

    func setColor(id: UUID, _ color: BrowserProfileColor) {
        list.setColor(id: id, color)
        persist()
    }

    func setArchiveAfter(id: UUID, _ archiveAfter: BrowserArchiveAfter) {
        list.setArchiveAfter(id: id, archiveAfter)
        persist()
    }

    /// Takes the profile out of the list; `BrowserWindowManager.deleteProfile`
    /// removes its windows and data.
    func remove(id: UUID) {
        list.remove(id: id)
        persist()
    }

    private func persist() {
        try? JSONFile.write(list, to: url)
        changes.notify()
    }
}

/// What a window shows of itself next to its tabs: "Private" with its
/// profile (color and name) when more than one profile exists ("Private ·
/// Work"), or a normal window's current Space (its emoji, name and color
/// mark) when more than one Space exists; nothing otherwise.
struct BrowserWindowMark: Equatable, Sendable {
    var isPrivate: Bool
    /// Nil while only one profile exists.
    var profileName: String?
    /// The color dot: the Space's mark, else the profile's color.
    var color: BrowserProfileColor?
    /// The current Space's name; nil without one (or while only one Space
    /// exists).
    var spaceName: String?
    var spaceIcon: BrowserSpaceIcon = .none

    init(kind: BrowserWindowKind, profile: BrowserProfile?) {
        isPrivate = kind.isPrivate
        profileName = profile?.name
        color = profile?.color
    }

    /// A normal window on `space`; `profile` (nil while only one exists)
    /// goes into the tooltip.
    init(space: BrowserSpace, profile: BrowserProfile?) {
        isPrivate = false
        profileName = profile?.name
        color = space.color
        spaceName = space.displayName
        spaceIcon = space.icon
    }

    /// The mark's words; nil when there is nothing to show.
    var text: String? {
        if let spaceName {
            if case let .emoji(emoji) = spaceIcon {
                return "\(emoji) \(spaceName)"
            }
            return spaceName
        }
        switch (isPrivate, profileName) {
        case (true, let name?): return "Private · \(name)"
        case (true, nil): return "Private"
        case (false, let name?): return name
        case (false, nil): return nil
        }
    }

    var toolTip: String? {
        var parts: [String] = []
        if let spaceName {
            parts.append("Space: \(spaceName)")
        }
        if let profileName {
            parts.append("Profile: \(profileName)")
        }
        if isPrivate {
            parts.append("Private window: no history, and cookies and site data go when it closes")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
