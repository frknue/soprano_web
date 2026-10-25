import Foundation

// MARK: - Store

/// The bookmark tree, shared by every window and profile, saved to
/// `bookmarks.json` after each change. A version 1 file is converted once
/// and kept as `bookmarks.json.migrated`; a file that doesn't decode at all
/// is kept as `bookmarks.json.corrupt` before the store starts empty.
@MainActor
final class BrowserBookmarkStore {
    private(set) var tree: BrowserBookmarkTree
    /// Every bookmark with its folder path, in tree order.
    private(set) var entries: [BrowserBookmarkEntry]
    let url: URL
    let changes = BrowserObservers<Void>()

    var migratedURL: URL { url.appendingPathExtension("migrated") }
    var corruptURL: URL { url.appendingPathExtension("corrupt") }

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("bookmarks.json")) {
        self.url = url
        let fileManager = FileManager.default
        let file = JSONFile.read(BrowserBookmarkFile.self, at: url)
        tree = file?.tree ?? BrowserBookmarkTree()
        entries = tree.entries()
        if let file, file.version < BrowserBookmarkFile.currentVersion {
            if !fileManager.fileExists(atPath: migratedURL.path) {
                try? fileManager.copyItem(at: url, to: migratedURL)
            }
            try? JSONFile.write(BrowserBookmarkFile(tree: tree), to: url)
        } else if file == nil, fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: corruptURL)
            try? fileManager.copyItem(at: url, to: corruptURL)
        }
    }

    /// Every bookmark in every folder, in tree order.
    var bookmarks: [BrowserBookmark] { entries.map(\.bookmark) }

    func isBookmarked(_ address: String) -> Bool {
        bookmark(url: address) != nil
    }

    /// The first bookmark (in tree order) for exactly this address.
    func bookmark(url address: String) -> BrowserBookmark? {
        entries.first { $0.bookmark.url == address }?.bookmark
    }

    func entry(id: UUID) -> BrowserBookmarkEntry? {
        entries.first { $0.bookmark.id == id }
    }

    /// Adds a bookmark first in `folderID` (the root when it's gone).
    @discardableResult
    func addBookmark(url address: String, title: String, to folderID: UUID = BrowserBookmarkTree.rootID) -> BrowserBookmark {
        let bookmark = BrowserBookmark(url: address, title: title)
        let folder = tree.folder(id: folderID) == nil ? BrowserBookmarkTree.rootID : folderID
        update { $0.insert(.bookmark(bookmark), into: folder, at: 0) }
        return bookmark
    }

    /// Inserts a whole node (a folder with its contents) into `folderID`
    /// at `index` (nil appends): the entry point for importers. Fails when
    /// the folder is missing or an id is already in the tree.
    @discardableResult
    func insert(_ node: BrowserBookmarkNode, into folderID: UUID = BrowserBookmarkTree.rootID, at index: Int? = nil) -> Bool {
        update { $0.insert(node, into: folderID, at: index) }
    }

    /// Adds an empty folder in `parentID` at `index` (nil appends).
    @discardableResult
    func addFolder(
        name: String,
        in parentID: UUID = BrowserBookmarkTree.rootID,
        at index: Int? = nil
    ) -> BrowserBookmarkFolder {
        let folder = BrowserBookmarkFolder(name: name)
        let parent = tree.folder(id: parentID) == nil ? BrowserBookmarkTree.rootID : parentID
        update { $0.insert(.folder(folder), into: parent, at: index) }
        return folder
    }

    @discardableResult
    func move(_ id: UUID, to folderID: UUID, at index: Int) -> Bool {
        update { $0.move(id, to: folderID, at: index) }
    }

    func rename(folder id: UUID, to name: String) {
        update { $0.rename(folder: id, to: name) }
    }

    func edit(bookmark id: UUID, title: String, url address: String) {
        update { $0.edit(bookmark: id, title: title, url: address) }
    }

    func remove(id: UUID) {
        update { $0.remove(id) != nil }
    }

    /// Bookmarks whose title, address or folder path contains `query`;
    /// every bookmark for an empty query.
    func matching(_ query: String) -> [BrowserBookmarkEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.bookmark.title.lowercased().contains(needle)
                || $0.bookmark.url.lowercased().contains(needle)
                || $0.path.contains { $0.lowercased().contains(needle) }
        }
    }

    /// Applies `change`; saves and notifies when the tree changed.
    @discardableResult
    private func update(_ change: (inout BrowserBookmarkTree) -> Bool) -> Bool {
        var next = tree
        guard change(&next) else { return false }
        guard next != tree else { return true }
        tree = next
        entries = next.entries()
        try? JSONFile.write(BrowserBookmarkFile(tree: next), to: url)
        changes.notify()
        return true
    }
}

/// Bookmark UI state in `UserDefaults`, shared by every window: which
/// sidebar folders are expanded and the folder ⌘D last used.
@MainActor
final class BrowserBookmarkUIState {
    static let expandedFoldersKey = "bookmarkExpandedFolders"
    static let lastFolderKey = "bookmarkLastFolder"

    private let defaults: UserDefaults
    private(set) var expandedFolders: Set<UUID>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.expandedFoldersKey) ?? []
        expandedFolders = Set(saved.compactMap(UUID.init(uuidString:)))
    }

    func setExpanded(_ expanded: Bool, folder id: UUID) {
        let changed = expanded ? expandedFolders.insert(id).inserted : expandedFolders.remove(id) != nil
        guard changed else { return }
        defaults.set(expandedFolders.map(\.uuidString).sorted(), forKey: Self.expandedFoldersKey)
    }

    var lastFolderID: UUID? {
        get { defaults.string(forKey: Self.lastFolderKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.lastFolderKey) }
    }
}

// MARK: - Nodes

/// A saved page. Its `id` stays the same when it moves between folders.
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

/// A folder of bookmarks and folders, in the order the user arranged them.
struct BrowserBookmarkFolder: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var addedAt: Date
    var children: [BrowserBookmarkNode]

    init(id: UUID = UUID(), name: String, addedAt: Date = Date(), children: [BrowserBookmarkNode] = []) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
        self.children = children
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Folder" : trimmed
    }

    /// Folders inside, nested ones included.
    var folderCount: Int {
        children.reduce(0) { count, node in
            guard let folder = node.folder else { return count }
            return count + 1 + folder.folderCount
        }
    }

    /// What Delete asks about: "It holds 3 bookmarks and 1 folder."
    var contentsSummary: String {
        func count(_ value: Int, _ noun: String) -> String {
            "\(value) \(noun)\(value == 1 ? "" : "s")"
        }
        let bookmarks = allBookmarks.count
        let folders = folderCount
        switch (bookmarks, folders) {
        case (0, 0): return "It is empty."
        case (_, 0): return "It holds \(count(bookmarks, "bookmark"))."
        case (0, _): return "It holds \(count(folders, "folder"))."
        default: return "It holds \(count(bookmarks, "bookmark")) and \(count(folders, "folder"))."
        }
    }

    /// Every bookmark inside, nested folders included, in order.
    var allBookmarks: [BrowserBookmark] {
        children.flatMap { node -> [BrowserBookmark] in
            switch node {
            case let .bookmark(bookmark): [bookmark]
            case let .folder(folder): folder.allBookmarks
            }
        }
    }
}

/// One entry of the tree: a bookmark or a folder.
enum BrowserBookmarkNode: Identifiable, Equatable, Sendable {
    case bookmark(BrowserBookmark)
    case folder(BrowserBookmarkFolder)

    var id: UUID {
        switch self {
        case let .bookmark(bookmark): bookmark.id
        case let .folder(folder): folder.id
        }
    }

    var title: String {
        switch self {
        case let .bookmark(bookmark): bookmark.displayTitle
        case let .folder(folder): folder.displayName
        }
    }

    var bookmark: BrowserBookmark? {
        if case let .bookmark(bookmark) = self { return bookmark }
        return nil
    }

    var folder: BrowserBookmarkFolder? {
        if case let .folder(folder) = self { return folder }
        return nil
    }

    var isFolder: Bool { folder != nil }
}

/// A bookmark with the folders it sits in (root excluded), for search,
/// suggestions and Vimium.
struct BrowserBookmarkEntry: Equatable, Sendable {
    var bookmark: BrowserBookmark
    var folderID: UUID
    /// Folder names from the top level down; empty at the top level.
    var path: [String]

    /// "Work › Docs", or "Bookmarks" at the top level.
    var pathText: String {
        path.isEmpty ? BrowserBookmarkTree.rootName : path.joined(separator: " › ")
    }

    /// Vimium's `b`/`B` line: "Work › Docs · <url>", the address alone at
    /// the top level.
    var detail: String {
        path.isEmpty ? bookmark.url : "\(pathText) · \(bookmark.url)"
    }
}

/// A folder a bookmark can go to (the folder picker, the Bookmarks menu).
struct BrowserBookmarkFolderEntry: Equatable, Sendable {
    var id: UUID
    var name: String
    /// 0 for the root ("Bookmarks").
    var depth: Int
}

// MARK: - Tree

/// The whole bookmark tree under one root folder. Every operation is pure
/// and keeps ids unique; operations that cannot apply return false or nil
/// and change nothing.
struct BrowserBookmarkTree: Equatable, Sendable {
    static let rootID = UUID(uuidString: "00000000-0000-0000-0000-00000000B00C")!
    static let rootName = "Bookmarks"
    /// The date of the root and of nodes saved without one.
    static let unknownDate = Date(timeIntervalSince1970: 0)

    private(set) var root: BrowserBookmarkFolder

    init(children: [BrowserBookmarkNode] = []) {
        self.init(root: BrowserBookmarkFolder(id: Self.rootID, name: Self.rootName, children: children))
    }

    /// Takes `root`'s children; a node whose id was already seen (the root's
    /// included) is dropped with its contents.
    init(root: BrowserBookmarkFolder) {
        var seen: Set<UUID> = [Self.rootID]
        self.root = BrowserBookmarkFolder(
            id: Self.rootID,
            name: Self.rootName,
            addedAt: Self.unknownDate,
            children: Self.unique(root.children, seen: &seen)
        )
    }

    private static func unique(_ nodes: [BrowserBookmarkNode], seen: inout Set<UUID>) -> [BrowserBookmarkNode] {
        var result: [BrowserBookmarkNode] = []
        for node in nodes where seen.insert(node.id).inserted {
            if case var .folder(folder) = node {
                folder.children = unique(folder.children, seen: &seen)
                result.append(.folder(folder))
            } else {
                result.append(node)
            }
        }
        return result
    }

    var isEmpty: Bool { root.children.isEmpty }

    // MARK: Lookup

    func node(id: UUID) -> BrowserBookmarkNode? {
        id == Self.rootID ? .folder(root) : Self.find(id, in: root.children)
    }

    func folder(id: UUID) -> BrowserBookmarkFolder? {
        node(id: id)?.folder
    }

    private static func find(_ id: UUID, in nodes: [BrowserBookmarkNode]) -> BrowserBookmarkNode? {
        for node in nodes {
            if node.id == id { return node }
            if case let .folder(folder) = node, let found = find(id, in: folder.children) {
                return found
            }
        }
        return nil
    }

    /// The folder holding `id` and its index there.
    func location(of id: UUID) -> (folderID: UUID, index: Int)? {
        Self.location(of: id, in: root)
    }

    private static func location(of id: UUID, in folder: BrowserBookmarkFolder) -> (folderID: UUID, index: Int)? {
        for (index, node) in folder.children.enumerated() {
            if node.id == id { return (folder.id, index) }
            if case let .folder(child) = node, let found = location(of: id, in: child) {
                return found
            }
        }
        return nil
    }

    /// Whether `id` is `ancestorID` itself or anywhere inside it.
    func contains(_ id: UUID, within ancestorID: UUID) -> Bool {
        guard let ancestor = node(id: ancestorID) else { return false }
        if ancestor.id == id { return true }
        guard let folder = ancestor.folder else { return false }
        return Self.find(id, in: folder.children) != nil
    }

    /// Every bookmark whose address is exactly `url`, in tree order.
    func bookmarks(url: String) -> [BrowserBookmark] {
        root.allBookmarks.filter { $0.url == url }
    }

    /// Every bookmark with its folder path, depth first in display order.
    func entries() -> [BrowserBookmarkEntry] {
        var result: [BrowserBookmarkEntry] = []
        func walk(_ folder: BrowserBookmarkFolder, path: [String]) {
            for node in folder.children {
                switch node {
                case let .bookmark(bookmark):
                    result.append(BrowserBookmarkEntry(bookmark: bookmark, folderID: folder.id, path: path))
                case let .folder(child):
                    walk(child, path: path + [child.displayName])
                }
            }
        }
        walk(root, path: [])
        return result
    }

    /// The root and every folder, depth first, skipping `excluded` and
    /// everything inside it (a folder can't move into itself).
    func folderEntries(excluding excluded: UUID? = nil) -> [BrowserBookmarkFolderEntry] {
        var result: [BrowserBookmarkFolderEntry] = []
        func walk(_ folder: BrowserBookmarkFolder, depth: Int) {
            guard folder.id != excluded else { return }
            result.append(BrowserBookmarkFolderEntry(id: folder.id, name: folder.displayName, depth: depth))
            for case let .folder(child) in folder.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// Where ⌘D puts a new bookmark: the folder last chosen, while it
    /// still exists, else the root.
    func folderForNewBookmark(lastUsed: UUID?) -> UUID {
        guard let lastUsed, folder(id: lastUsed) != nil else { return Self.rootID }
        return lastUsed
    }

    // MARK: Changes

    /// Inserts `node` into `folderID` at `index` (clamped; nil appends).
    /// Fails when the folder is missing or an id in `node` is taken.
    @discardableResult
    mutating func insert(_ node: BrowserBookmarkNode, into folderID: UUID, at index: Int? = nil) -> Bool {
        guard folder(id: folderID) != nil else { return false }
        var ids: Set<UUID> = []
        Self.collectIDs(node, into: &ids)
        guard ids.allSatisfy({ self.node(id: $0) == nil }) else { return false }
        return updateFolder(folderID) { folder in
            let position = min(max(index ?? folder.children.count, 0), folder.children.count)
            folder.children.insert(node, at: position)
        }
    }

    private static func collectIDs(_ node: BrowserBookmarkNode, into ids: inout Set<UUID>) {
        ids.insert(node.id)
        if case let .folder(folder) = node {
            for child in folder.children { collectIDs(child, into: &ids) }
        }
    }

    /// Whether `id` may move into `folderID`: never the root, never a
    /// folder into itself or one of its descendants.
    func canMove(_ id: UUID, into folderID: UUID) -> Bool {
        guard id != Self.rootID, node(id: id) != nil, folder(id: folderID) != nil else { return false }
        return !contains(folderID, within: id)
    }

    /// Moves `id` into `folderID` before the item now at `index` (the gap
    /// a drop lands in, counted before `id` leaves its place; clamped).
    @discardableResult
    mutating func move(_ id: UUID, to folderID: UUID, at index: Int) -> Bool {
        guard canMove(id, into: folderID),
              let source = location(of: id),
              let destination = folder(id: folderID)
        else { return false }
        var target = min(max(index, 0), destination.children.count)
        if source.folderID == folderID, source.index < target {
            target -= 1
        }
        guard let node = remove(id) else { return false }
        return updateFolder(folderID) { folder in
            folder.children.insert(node, at: min(target, folder.children.count))
        }
    }

    @discardableResult
    mutating func rename(folder id: UUID, to name: String) -> Bool {
        guard id != Self.rootID else { return false }
        return updateNode(id) { node in
            guard case var .folder(folder) = node else { return false }
            folder.name = name
            node = .folder(folder)
            return true
        }
    }

    @discardableResult
    mutating func edit(bookmark id: UUID, title: String, url: String) -> Bool {
        updateNode(id) { node in
            guard case var .bookmark(bookmark) = node else { return false }
            bookmark.title = title
            bookmark.url = url
            node = .bookmark(bookmark)
            return true
        }
    }

    /// Removes `id` (a folder with everything inside) and returns it.
    @discardableResult
    mutating func remove(_ id: UUID) -> BrowserBookmarkNode? {
        guard let location = location(of: id) else { return nil }
        var removed: BrowserBookmarkNode?
        updateFolder(location.folderID) { folder in
            removed = folder.children.remove(at: location.index)
        }
        return removed
    }

    // MARK: Helpers

    @discardableResult
    private mutating func updateFolder(_ id: UUID, _ change: (inout BrowserBookmarkFolder) -> Void) -> Bool {
        if id == Self.rootID {
            change(&root)
            return true
        }
        return updateNode(id) { node in
            guard case var .folder(folder) = node else { return false }
            change(&folder)
            node = .folder(folder)
            return true
        }
    }

    private mutating func updateNode(_ id: UUID, _ change: (inout BrowserBookmarkNode) -> Bool) -> Bool {
        Self.update(id, in: &root.children, change)
    }

    private static func update(
        _ id: UUID,
        in nodes: inout [BrowserBookmarkNode],
        _ change: (inout BrowserBookmarkNode) -> Bool
    ) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                return change(&nodes[index])
            }
            if case var .folder(folder) = nodes[index], find(id, in: folder.children) != nil {
                let changed = update(id, in: &folder.children, change)
                nodes[index] = .folder(folder)
                return changed
            }
        }
        return false
    }
}

// MARK: - File

/// `bookmarks.json`: `{ "version": 2, "root": { folder } }`. Folders are
/// `{ "type": "folder", "id", "name", "addedAt", "children": [...] }`,
/// bookmarks `{ "type": "bookmark", "id", "url", "title", "addedAt" }`.
/// Version 1 (stage 1) was a flat `{ "version": 1, "entries": [...] }` list
/// (or a bare array); it decodes into the root in the order the sidebar
/// showed it, newest first. A node that doesn't decode is skipped and a
/// repeated id dropped.
struct BrowserBookmarkFile: Codable, Equatable {
    static let currentVersion = 2

    /// The version of the file this was read from.
    var version: Int
    var tree: BrowserBookmarkTree

    init(tree: BrowserBookmarkTree) {
        self.version = Self.currentVersion
        self.tree = tree
    }

    private enum CodingKeys: String, CodingKey {
        case version, root
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.root) {
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
            let root = (try? c.decode(BrowserBookmarkFolder.self, forKey: .root))
                ?? BrowserBookmarkFolder(id: BrowserBookmarkTree.rootID, name: BrowserBookmarkTree.rootName)
            tree = BrowserBookmarkTree(root: root)
            return
        }
        let list = try JSONList<BrowserBookmark>(from: decoder)
        version = 1
        // `sorted` is stable: equal dates keep the file's order.
        let ordered = list.entries.sorted { $0.addedAt > $1.addedAt }
        tree = BrowserBookmarkTree(children: ordered.map(BrowserBookmarkNode.bookmark))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(tree.root, forKey: .root)
    }
}

private enum BrowserBookmarkNodeKeys: String, CodingKey {
    case type, id, url, title, name, addedAt, children
}

extension BrowserBookmarkFolder: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserBookmarkNodeKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
            addedAt: (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? BrowserBookmarkTree.unknownDate,
            children: (try? c.decodeIfPresent(LossyArray<BrowserBookmarkNode>.self, forKey: .children))?.elements ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BrowserBookmarkNodeKeys.self)
        try c.encode("folder", forKey: .type)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(children, forKey: .children)
    }
}

extension BrowserBookmarkNode: Codable {
    /// `type` decides; without one, `children` means a folder and `url` a
    /// bookmark. A bookmark needs a non-empty `url`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserBookmarkNodeKeys.self)
        let type = try? c.decodeIfPresent(String.self, forKey: .type)
        let isFolder = type.map { $0 == "folder" } ?? c.contains(.children)
        if isFolder {
            self = .folder(try BrowserBookmarkFolder(from: decoder))
            return
        }
        guard type == nil || type == "bookmark",
              let url = try? c.decode(String.self, forKey: .url),
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Not a bookmark")
        }
        self = .bookmark(BrowserBookmark(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            url: url,
            title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
            addedAt: (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? BrowserBookmarkTree.unknownDate
        ))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .folder(folder):
            try folder.encode(to: encoder)
        case let .bookmark(bookmark):
            var c = encoder.container(keyedBy: BrowserBookmarkNodeKeys.self)
            try c.encode("bookmark", forKey: .type)
            try c.encode(bookmark.id, forKey: .id)
            try c.encode(bookmark.url, forKey: .url)
            try c.encode(bookmark.title, forKey: .title)
            try c.encode(bookmark.addedAt, forKey: .addedAt)
        }
    }
}

// MARK: - Outline

/// The sidebar's Bookmarks outline: the visible rows for an expanded set,
/// and where a drag dropped among them lands.
enum BrowserBookmarkOutline {
    struct Row: Equatable {
        var node: BrowserBookmarkNode
        var depth: Int
        /// The folder holding the node and its index there.
        var folderID: UUID
        var index: Int
        var isExpanded: Bool
    }

    /// A drop as the table proposes it: on a row, or in the gap above row
    /// `n` (`n == rows.count` is the gap after the last row).
    enum Drop: Equatable {
        case on(Int)
        case above(Int)
    }

    struct Destination: Equatable {
        var folderID: UUID
        var index: Int
    }

    static func rows(_ tree: BrowserBookmarkTree, expanded: Set<UUID>) -> [Row] {
        var result: [Row] = []
        func walk(_ folder: BrowserBookmarkFolder, depth: Int) {
            for (index, node) in folder.children.enumerated() {
                let isExpanded = node.isFolder && expanded.contains(node.id)
                result.append(Row(node: node, depth: depth, folderID: folder.id, index: index, isExpanded: isExpanded))
                if isExpanded, let child = node.folder {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(tree.root, depth: 0)
        return result
    }

    /// On a folder: its end. Above a row: that row's place in its folder.
    /// After the last row: the end of the root. On a bookmark: nowhere.
    static func destination(for drop: Drop, rows: [Row], tree: BrowserBookmarkTree) -> Destination? {
        switch drop {
        case let .on(row):
            guard rows.indices.contains(row), let folder = rows[row].node.folder else { return nil }
            return Destination(folderID: folder.id, index: folder.children.count)
        case let .above(row):
            if row == rows.count {
                return Destination(folderID: BrowserBookmarkTree.rootID, index: tree.root.children.count)
            }
            guard rows.indices.contains(row) else { return nil }
            return Destination(folderID: rows[row].folderID, index: rows[row].index)
        }
    }
}
