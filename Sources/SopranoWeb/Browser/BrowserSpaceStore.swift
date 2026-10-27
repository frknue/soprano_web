import Foundation

// MARK: - Store

/// Every Space with its pinned tree, and every profile's favorites, shared
/// by every window and saved to `spaces.json` (`BrowserSpacesFile`) after
/// each change. Every profile it is told about keeps at least one Space.
///
/// When `spaces.json` is missing (or unreadable, which is kept as
/// `spaces.json.corrupt`) the store starts with one Space per profile —
/// the profile's name and color, no icon — and stage 2's `bookmarks.json`
/// (version 1 or 2), when present, becomes the Default profile's Space's
/// pinned tree and is kept as `bookmarks.json.migrated`.
@MainActor
final class BrowserSpaceStore {
    let url: URL
    /// Stage 2's bookmark file, read once when `spaces.json` is created.
    let bookmarksURL: URL
    let changes = BrowserObservers<Void>()
    private(set) var list: BrowserSpaceList
    /// Every Space's pins with their folder paths, in tree order.
    private var entryCache: [UUID: [BrowserPinEntry]] = [:]

    var corruptURL: URL { url.appendingPathExtension("corrupt") }
    var migratedBookmarksURL: URL { bookmarksURL.appendingPathExtension("migrated") }

    init(
        url: URL = BrowserFiles.supportDirectory().appendingPathComponent("spaces.json"),
        profiles: [BrowserProfile],
        bookmarksURL: URL? = nil
    ) {
        self.url = url
        self.bookmarksURL = bookmarksURL ?? url.deletingLastPathComponent().appendingPathComponent("bookmarks.json")
        let fileManager = FileManager.default
        var needsWrite = false
        var migratedBookmarks = false
        if let file = JSONFile.read(BrowserSpacesFile.self, at: url) {
            list = file.list
        } else {
            if fileManager.fileExists(atPath: url.path) {
                let corruptURL = url.appendingPathExtension("corrupt")
                try? fileManager.removeItem(at: corruptURL)
                try? fileManager.copyItem(at: url, to: corruptURL)
            }
            let bookmarks = JSONFile.read(BrowserBookmarksFile.self, at: self.bookmarksURL)
            list = Self.initialList(profiles: profiles, pinned: bookmarks?.tree ?? BrowserPinTree())
            migratedBookmarks = bookmarks != nil
            needsWrite = true
        }
        if list.reconcile(with: profiles) {
            needsWrite = true
        }
        rebuildEntries()
        guard needsWrite, (try? JSONFile.write(BrowserSpacesFile(list: list), to: url)) != nil else { return }
        if migratedBookmarks {
            // The migrated tree holds everything an older `.migrated` copy
            // (stage 2's version 1 file) did.
            try? fileManager.removeItem(at: migratedBookmarksURL)
            try? fileManager.moveItem(at: self.bookmarksURL, to: migratedBookmarksURL)
        }
    }

    /// One Space per profile, in profile order; `pinned` goes to Default's
    /// (the first profile's when Default isn't listed).
    private static func initialList(profiles: [BrowserProfile], pinned: BrowserPinTree) -> BrowserSpaceList {
        let owner = profiles.first(where: \.isDefault)?.id ?? profiles.first?.id
        var list = BrowserSpaceList()
        for profile in profiles {
            list.create(
                name: profile.name,
                color: profile.color,
                profileID: profile.id,
                pinned: profile.id == owner ? pinned : BrowserPinTree()
            )
        }
        return list
    }

    // MARK: Spaces

    /// Every Space in display order.
    var spaces: [BrowserSpace] { list.spaces }

    func space(id: UUID) -> BrowserSpace? { list.space(id: id) }
    func spaces(ofProfile profileID: UUID) -> [BrowserSpace] { list.spaces(ofProfile: profileID) }
    func firstSpace(ofProfile profileID: UUID) -> BrowserSpace? { list.firstSpace(ofProfile: profileID) }

    /// Appends a Space (nil when `id` is taken); an empty name becomes
    /// "Space". Importers pass `importedFrom` and the pinned tree.
    @discardableResult
    func createSpace(
        name: String,
        icon: BrowserSpaceIcon = .none,
        color: BrowserProfileColor,
        profileID: UUID,
        pinned: BrowserPinTree = BrowserPinTree(),
        importedFrom: String? = nil
    ) -> BrowserSpace? {
        var created: BrowserSpace?
        update { list in
            created = list.create(
                name: name,
                icon: icon,
                color: color,
                profileID: profileID,
                pinned: pinned,
                importedFrom: importedFrom
            )
            return created != nil
        }
        return created
    }

    /// The profile's first Space, made (named after it, in its color) when
    /// it has none: a new profile's Space.
    @discardableResult
    func ensureSpace(forProfile profile: BrowserProfile) -> BrowserSpace {
        if let existing = list.firstSpace(ofProfile: profile.id) {
            return existing
        }
        var space = BrowserSpace(name: profile.name, color: profile.color, profileID: profile.id)
        update { list in
            space = list.ensureSpace(for: profile)
            return true
        }
        return space
    }

    /// An importer's first Space of a profile it just made: takes over
    /// the Space the profile was given instead of adding a second one
    /// (see `BrowserSpaceList.adopt`).
    @discardableResult
    func adoptSpace(
        _ id: UUID,
        name: String,
        icon: BrowserSpaceIcon,
        color: BrowserProfileColor,
        pinned: BrowserPinTree,
        importedFrom: String
    ) -> Bool {
        update { $0.adopt(id, name: name, icon: icon, color: color, pinned: pinned, importedFrom: importedFrom) }
    }

    func space(importedFrom source: String) -> BrowserSpace? { list.space(importedFrom: source) }

    /// Every profile in `profiles` gets a Space when it has none; Spaces
    /// and favorites of profiles not in it go.
    func reconcile(with profiles: [BrowserProfile]) {
        update { $0.reconcile(with: profiles) }
    }

    @discardableResult
    func renameSpace(_ id: UUID, to name: String) -> Bool {
        update { $0.rename(id, to: name) }
    }

    @discardableResult
    func setSpaceIcon(_ id: UUID, _ icon: BrowserSpaceIcon) -> Bool {
        update { $0.setIcon(id, icon) }
    }

    @discardableResult
    func setSpaceColor(_ id: UUID, _ color: BrowserProfileColor) -> Bool {
        update { $0.setColor(id, color) }
    }

    /// Refused for its profile's last Space.
    @discardableResult
    func setSpaceProfile(_ id: UUID, _ profileID: UUID) -> Bool {
        update { $0.setProfile(id, profileID) }
    }

    /// Moves `id` before the Space now at `index` (counted before it leaves).
    @discardableResult
    func moveSpace(_ id: UUID, to index: Int) -> Bool {
        update { $0.move(id, to: index) }
    }

    /// Deletes a Space and its pins; refused for its profile's last Space.
    @discardableResult
    func deleteSpace(_ id: UUID) -> Bool {
        update { $0.delete(id) }
    }

    /// A deleted profile's Spaces and favorites.
    func deleteSpaces(ofProfile profileID: UUID) {
        update { list in
            let before = list
            list.deleteSpaces(ofProfile: profileID)
            return list != before
        }
    }

    // MARK: Pins (one tree per Space)

    /// The Space's pinned tree; empty for an unknown Space.
    func pinTree(inSpace spaceID: UUID) -> BrowserPinTree {
        list.space(id: spaceID)?.pinned ?? BrowserPinTree()
    }

    /// Every pin of the Space with its folder path, in tree order.
    func pinEntries(inSpace spaceID: UUID) -> [BrowserPinEntry] {
        entryCache[spaceID] ?? []
    }

    /// Every pin of the Space in every folder, in tree order.
    func pins(inSpace spaceID: UUID) -> [BrowserPin] {
        pinEntries(inSpace: spaceID).map(\.pin)
    }

    /// The Space's first pin (in tree order) for exactly this address.
    func pin(url address: String, inSpace spaceID: UUID) -> BrowserPin? {
        pinEntries(inSpace: spaceID).first { $0.pin.url == address }?.pin
    }

    func isPinned(_ address: String, inSpace spaceID: UUID) -> Bool {
        pin(url: address, inSpace: spaceID) != nil
    }

    /// Adds a pin first in `folderID` (the root when it's gone); nil when
    /// the Space is gone.
    @discardableResult
    func addPin(
        url address: String,
        title: String,
        to folderID: UUID = BrowserPinTree.rootID,
        inSpace spaceID: UUID
    ) -> BrowserPin? {
        let pin = BrowserPin(url: address, title: title)
        let applied = update { list in
            list.updatePins(in: spaceID) { tree in
                let folder = tree.folder(id: folderID) == nil ? BrowserPinTree.rootID : folderID
                return tree.insert(.pin(pin), into: folder, at: 0)
            }
        }
        return applied ? pin : nil
    }

    /// Inserts a whole node (a folder with its contents) into `folderID`
    /// at `index` (nil appends): the entry point for importers. Fails when
    /// the Space or folder is missing or an id is already in the tree.
    @discardableResult
    func insert(
        _ node: BrowserPinNode,
        into folderID: UUID = BrowserPinTree.rootID,
        at index: Int? = nil,
        inSpace spaceID: UUID
    ) -> Bool {
        update { $0.updatePins(in: spaceID) { $0.insert(node, into: folderID, at: index) } }
    }

    /// Adds an empty folder in `parentID` at `index` (nil appends).
    @discardableResult
    func addPinFolder(
        name: String,
        in parentID: UUID = BrowserPinTree.rootID,
        at index: Int? = nil,
        inSpace spaceID: UUID
    ) -> BrowserPinFolder? {
        let folder = BrowserPinFolder(name: name)
        let applied = update { list in
            list.updatePins(in: spaceID) { tree in
                let parent = tree.folder(id: parentID) == nil ? BrowserPinTree.rootID : parentID
                return tree.insert(.folder(folder), into: parent, at: index)
            }
        }
        return applied ? folder : nil
    }

    @discardableResult
    func movePin(_ id: UUID, to folderID: UUID, at index: Int, inSpace spaceID: UUID) -> Bool {
        update { $0.updatePins(in: spaceID) { $0.move(id, to: folderID, at: index) } }
    }

    func renamePinFolder(_ id: UUID, to name: String, inSpace spaceID: UUID) {
        update { $0.updatePins(in: spaceID) { $0.rename(folder: id, to: name) } }
    }

    func editPin(_ id: UUID, title: String, url address: String, inSpace spaceID: UUID) {
        update { $0.updatePins(in: spaceID) { $0.edit(pin: id, title: title, url: address) } }
    }

    func removePin(_ id: UUID, inSpace spaceID: UUID) {
        update { $0.updatePins(in: spaceID) { $0.remove(id) != nil } }
    }

    /// The Space's pins whose title, address or folder path contains
    /// `query`; every pin for an empty query.
    func matchingPins(_ query: String, inSpace spaceID: UUID) -> [BrowserPinEntry] {
        let entries = pinEntries(inSpace: spaceID)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.pin.title.lowercased().contains(needle)
                || $0.pin.url.lowercased().contains(needle)
                || $0.path.contains { $0.lowercased().contains(needle) }
        }
    }

    /// What a tab of Space `spaceID` may be linked to (its pins, its
    /// profile's favorites); nothing for an unknown Space.
    func linkTargets(inSpace spaceID: UUID) -> BrowserPinLinks.Targets {
        list.space(id: spaceID).map(list.linkTargets(of:)) ?? BrowserPinLinks.Targets()
    }

    // MARK: Favorites (per profile, at most 12)

    func favorites(ofProfile profileID: UUID) -> [BrowserPin] {
        list.favorites(ofProfile: profileID).items
    }

    /// Adds a favorite at `index` (nil appends); nil when the profile has
    /// `BrowserFavorites.limit` already.
    @discardableResult
    func addFavorite(url address: String, title: String, at index: Int? = nil, ofProfile profileID: UUID) -> BrowserPin? {
        let pin = BrowserPin(url: address, title: title)
        return insertFavorite(pin, at: index, ofProfile: profileID) ? pin : nil
    }

    /// Inserts `pin` as it is (importers); refused when full or its id is
    /// already a favorite.
    @discardableResult
    func insertFavorite(_ pin: BrowserPin, at index: Int? = nil, ofProfile profileID: UUID) -> Bool {
        update { $0.updateFavorites(ofProfile: profileID) { $0.add(pin, at: index) } }
    }

    @discardableResult
    func moveFavorite(_ id: UUID, to index: Int, ofProfile profileID: UUID) -> Bool {
        update { $0.updateFavorites(ofProfile: profileID) { $0.move(id, to: index) } }
    }

    func removeFavorite(_ id: UUID, ofProfile profileID: UUID) {
        update { $0.updateFavorites(ofProfile: profileID) { $0.remove(id) != nil } }
    }

    @discardableResult
    func replaceFavorite(_ id: UUID, url address: String, title: String, ofProfile profileID: UUID) -> Bool {
        update { $0.updateFavorites(ofProfile: profileID) { $0.replace(id, url: address, title: title) } }
    }

    // MARK: Saving

    /// Applies `change`; saves and notifies when the list changed.
    @discardableResult
    private func update(_ change: (inout BrowserSpaceList) -> Bool) -> Bool {
        var next = list
        guard change(&next) else { return false }
        guard next != list else { return true }
        list = next
        rebuildEntries()
        try? JSONFile.write(BrowserSpacesFile(list: next), to: url)
        changes.notify()
        return true
    }

    private func rebuildEntries() {
        entryCache = Dictionary(uniqueKeysWithValues: list.spaces.map { ($0.id, $0.pinned.entries()) })
    }
}

// MARK: - UI state

/// Pin UI state in `UserDefaults`, shared by every window: which outline
/// folders are expanded, and per Space the folder ⌘D last used. Stage 2's
/// keys are read while the new ones are unset.
@MainActor
final class BrowserPinUIState {
    static let expandedFoldersKey = "pinExpandedFolders"
    static let lastFoldersKey = "pinLastFolders"
    static let legacyExpandedFoldersKey = "bookmarkExpandedFolders"
    static let legacyLastFolderKey = "bookmarkLastFolder"

    private let defaults: UserDefaults
    private(set) var expandedFolders: Set<UUID>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.expandedFoldersKey)
            ?? defaults.stringArray(forKey: Self.legacyExpandedFoldersKey)
            ?? []
        expandedFolders = Set(saved.compactMap(UUID.init(uuidString:)))
    }

    func setExpanded(_ expanded: Bool, folder id: UUID) {
        let changed = expanded ? expandedFolders.insert(id).inserted : expandedFolders.remove(id) != nil
        guard changed else { return }
        defaults.set(expandedFolders.map(\.uuidString).sorted(), forKey: Self.expandedFoldersKey)
    }

    /// The folder ⌘D last used in the Space (stage 2's single folder until
    /// the Space has its own; `folderForNewPin` drops one that's gone).
    func lastFolderID(inSpace spaceID: UUID) -> UUID? {
        let saved = defaults.dictionary(forKey: Self.lastFoldersKey) as? [String: String] ?? [:]
        let value = saved[spaceID.uuidString] ?? defaults.string(forKey: Self.legacyLastFolderKey)
        return value.flatMap(UUID.init(uuidString:))
    }

    func setLastFolderID(_ folderID: UUID?, inSpace spaceID: UUID) {
        var saved = defaults.dictionary(forKey: Self.lastFoldersKey) as? [String: String] ?? [:]
        saved[spaceID.uuidString] = folderID?.uuidString
        defaults.set(saved, forKey: Self.lastFoldersKey)
    }
}
