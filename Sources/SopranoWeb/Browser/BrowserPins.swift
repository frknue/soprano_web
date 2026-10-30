import Foundation

// MARK: - Nodes

/// A pinned page (stage 2's bookmark). Its `id` stays the same when it
/// moves between folders; its title is the user's.
struct BrowserPin: Codable, Identifiable, Equatable, Sendable {
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

/// A folder of pins and folders, in the order the user arranged them. A
/// live folder (`source` set) shows what its source fetches before its
/// children; nothing fetched is ever saved in `children`.
struct BrowserPinFolder: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var addedAt: Date
    var children: [BrowserPinNode]
    var source: BrowserLiveFolderSource?

    init(
        id: UUID = UUID(),
        name: String,
        addedAt: Date = Date(),
        children: [BrowserPinNode] = [],
        source: BrowserLiveFolderSource? = nil
    ) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
        self.children = children
        self.source = source
    }

    var isLive: Bool { source != nil }

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
        let pins = allPins.count
        let folders = folderCount
        switch (pins, folders) {
        case (0, 0): return "It is empty."
        case (_, 0): return "It holds \(count(pins, "bookmark"))."
        case (0, _): return "It holds \(count(folders, "folder"))."
        default: return "It holds \(count(pins, "bookmark")) and \(count(folders, "folder"))."
        }
    }

    /// Every pin inside, nested folders included, in order.
    var allPins: [BrowserPin] {
        children.flatMap { node -> [BrowserPin] in
            switch node {
            case let .pin(pin): [pin]
            case let .folder(folder): folder.allPins
            }
        }
    }
}

/// One entry of the tree: a pin or a folder.
enum BrowserPinNode: Identifiable, Equatable, Sendable {
    case pin(BrowserPin)
    case folder(BrowserPinFolder)

    var id: UUID {
        switch self {
        case let .pin(pin): pin.id
        case let .folder(folder): folder.id
        }
    }

    var title: String {
        switch self {
        case let .pin(pin): pin.displayTitle
        case let .folder(folder): folder.displayName
        }
    }

    var pin: BrowserPin? {
        if case let .pin(pin) = self { return pin }
        return nil
    }

    var folder: BrowserPinFolder? {
        if case let .folder(folder) = self { return folder }
        return nil
    }

    var isFolder: Bool { folder != nil }
}

/// A pin with the folders it sits in (root excluded), for search,
/// suggestions and Vimium.
struct BrowserPinEntry: Equatable, Sendable {
    var pin: BrowserPin
    var folderID: UUID
    /// Folder names from the top level down; empty at the top level.
    var path: [String]

    /// "Work › Docs", or the root's name at the top level.
    var pathText: String {
        path.isEmpty ? BrowserPinTree.rootName : path.joined(separator: " › ")
    }

    /// Vimium's `b`/`B` line: "Work › Docs · <url>", the address alone at
    /// the top level.
    var detail: String {
        path.isEmpty ? pin.url : "\(pathText) · \(pin.url)"
    }
}

/// A folder a pin can go to (the folder picker, the Bookmarks menu).
struct BrowserPinFolderEntry: Equatable, Sendable {
    var id: UUID
    var name: String
    /// 0 for the root.
    var depth: Int
}

// MARK: - Tree

/// One Space's pinned tree under one root folder. Every operation is pure
/// and keeps ids unique; operations that cannot apply return false or nil
/// and change nothing.
struct BrowserPinTree: Equatable, Sendable {
    /// Every Space's tree has this root id.
    static let rootID = UUID(uuidString: "00000000-0000-0000-0000-00000000B00C")!
    /// Shown for the top level (folder picker, search paths); the sidebar
    /// still calls the tree Bookmarks until the rail shows pins.
    static let rootName = "Bookmarks"
    /// The date of the root and of nodes saved without one.
    static let unknownDate = Date(timeIntervalSince1970: 0)

    private(set) var root: BrowserPinFolder

    init(children: [BrowserPinNode] = []) {
        self.init(root: BrowserPinFolder(id: Self.rootID, name: Self.rootName, children: children))
    }

    /// Takes `root`'s children; a node whose id was already seen (the root's
    /// included) is dropped with its contents.
    init(root: BrowserPinFolder) {
        var seen: Set<UUID> = [Self.rootID]
        self.root = BrowserPinFolder(
            id: Self.rootID,
            name: Self.rootName,
            addedAt: Self.unknownDate,
            children: Self.unique(root.children, seen: &seen)
        )
    }

    private static func unique(_ nodes: [BrowserPinNode], seen: inout Set<UUID>) -> [BrowserPinNode] {
        var result: [BrowserPinNode] = []
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

    func node(id: UUID) -> BrowserPinNode? {
        id == Self.rootID ? .folder(root) : Self.find(id, in: root.children)
    }

    func folder(id: UUID) -> BrowserPinFolder? {
        node(id: id)?.folder
    }

    private static func find(_ id: UUID, in nodes: [BrowserPinNode]) -> BrowserPinNode? {
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

    private static func location(of id: UUID, in folder: BrowserPinFolder) -> (folderID: UUID, index: Int)? {
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

    /// Every pin whose address is exactly `url`, in tree order.
    func pins(url: String) -> [BrowserPin] {
        root.allPins.filter { $0.url == url }
    }

    /// Every pin with its folder path, depth first in display order.
    func entries() -> [BrowserPinEntry] {
        var result: [BrowserPinEntry] = []
        func walk(_ folder: BrowserPinFolder, path: [String]) {
            for node in folder.children {
                switch node {
                case let .pin(pin):
                    result.append(BrowserPinEntry(pin: pin, folderID: folder.id, path: path))
                case let .folder(child):
                    walk(child, path: path + [child.displayName])
                }
            }
        }
        walk(root, path: [])
        return result
    }

    /// The root and every folder a pin or folder may go to, depth first,
    /// skipping `excluded` and everything inside it (a folder can't move
    /// into itself) and live folders (they hold what they fetch).
    func folderEntries(excluding excluded: UUID? = nil) -> [BrowserPinFolderEntry] {
        var result: [BrowserPinFolderEntry] = []
        func walk(_ folder: BrowserPinFolder, depth: Int) {
            guard folder.id != excluded, !folder.isLive else { return }
            result.append(BrowserPinFolderEntry(id: folder.id, name: folder.displayName, depth: depth))
            for case let .folder(child) in folder.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// Every live folder with its source, depth first.
    func liveFolders() -> [(id: UUID, source: BrowserLiveFolderSource)] {
        var result: [(id: UUID, source: BrowserLiveFolderSource)] = []
        func walk(_ folder: BrowserPinFolder) {
            for case let .folder(child) in folder.children {
                if let source = child.source { result.append((child.id, source)) }
                walk(child)
            }
        }
        walk(root)
        return result
    }

    /// The tree as it is shown: each live folder's `items` (by folder id)
    /// before its own children. Not for saving.
    func fillingLiveFolders(_ items: (UUID) -> [BrowserPin]) -> BrowserPinTree {
        func fill(_ nodes: [BrowserPinNode]) -> [BrowserPinNode] {
            nodes.map { node in
                guard case var .folder(folder) = node else { return node }
                folder.children = fill(folder.children)
                if folder.isLive {
                    folder.children = items(folder.id).map(BrowserPinNode.pin) + folder.children
                }
                return .folder(folder)
            }
        }
        var tree = self
        tree.root.children = fill(root.children)
        return tree
    }

    /// Where ⌘D puts a new pin: the folder last chosen, while it still
    /// exists and isn't live, else the root.
    func folderForNewPin(lastUsed: UUID?) -> UUID {
        guard let lastUsed, let folder = folder(id: lastUsed), !folder.isLive else { return Self.rootID }
        return lastUsed
    }

    // MARK: Changes

    /// Inserts `node` into `folderID` at `index` (clamped; nil appends).
    /// Fails when the folder is missing or an id in `node` is taken.
    @discardableResult
    mutating func insert(_ node: BrowserPinNode, into folderID: UUID, at index: Int? = nil) -> Bool {
        guard folder(id: folderID) != nil else { return false }
        var ids: Set<UUID> = []
        Self.collectIDs(node, into: &ids)
        guard ids.allSatisfy({ self.node(id: $0) == nil }) else { return false }
        return updateFolder(folderID) { folder in
            let position = min(max(index ?? folder.children.count, 0), folder.children.count)
            folder.children.insert(node, at: position)
        }
    }

    private static func collectIDs(_ node: BrowserPinNode, into ids: inout Set<UUID>) {
        ids.insert(node.id)
        if case let .folder(folder) = node {
            for child in folder.children { collectIDs(child, into: &ids) }
        }
    }

    /// Whether `id` may move into `folderID`: never the root, never a
    /// folder into itself or one of its descendants, never into a live
    /// folder.
    func canMove(_ id: UUID, into folderID: UUID) -> Bool {
        guard id != Self.rootID, node(id: id) != nil, let destination = folder(id: folderID), !destination.isLive
        else { return false }
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

    /// Makes folder `id` live (or plain again with nil).
    @discardableResult
    mutating func setSource(folder id: UUID, to source: BrowserLiveFolderSource?) -> Bool {
        guard id != Self.rootID else { return false }
        return updateNode(id) { node in
            guard case var .folder(folder) = node else { return false }
            folder.source = source
            node = .folder(folder)
            return true
        }
    }

    @discardableResult
    mutating func edit(pin id: UUID, title: String, url: String) -> Bool {
        updateNode(id) { node in
            guard case var .pin(pin) = node else { return false }
            pin.title = title
            pin.url = url
            node = .pin(pin)
            return true
        }
    }

    /// Removes `id` (a folder with everything inside) and returns it.
    @discardableResult
    mutating func remove(_ id: UUID) -> BrowserPinNode? {
        guard let location = location(of: id) else { return nil }
        var removed: BrowserPinNode?
        updateFolder(location.folderID) { folder in
            removed = folder.children.remove(at: location.index)
        }
        return removed
    }

    // MARK: Helpers

    @discardableResult
    private mutating func updateFolder(_ id: UUID, _ change: (inout BrowserPinFolder) -> Void) -> Bool {
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

    private mutating func updateNode(_ id: UUID, _ change: (inout BrowserPinNode) -> Bool) -> Bool {
        Self.update(id, in: &root.children, change)
    }

    private static func update(
        _ id: UUID,
        in nodes: inout [BrowserPinNode],
        _ change: (inout BrowserPinNode) -> Bool
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

// MARK: - Coding

/// Folders are `{ "type": "folder", "id", "name", "addedAt", "children": [...] }`,
/// pins `{ "type": "pin", "id", "url", "title", "addedAt" }` (stage 2's
/// `"type": "bookmark"` reads as a pin).
private enum BrowserPinNodeKeys: String, CodingKey {
    case type, id, url, title, name, addedAt, children, source
}

/// A live folder is still `"type": "folder"` with a `source` object
/// (`{"kind": "githubPullRequests", "repo"}` or `{"kind": "githubSearch",
/// "query"}`): an older build reads it as a plain folder. A source that
/// doesn't decode leaves a plain folder.
extension BrowserPinFolder: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserPinNodeKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
            addedAt: (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? BrowserPinTree.unknownDate,
            children: (try? c.decodeIfPresent(LossyArray<BrowserPinNode>.self, forKey: .children))?.elements ?? [],
            source: (try? c.decodeIfPresent(BrowserLiveFolderSource.self, forKey: .source)) ?? nil
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: BrowserPinNodeKeys.self)
        try c.encode("folder", forKey: .type)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(children, forKey: .children)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

extension BrowserPinNode: Codable {
    /// `type` decides; without one, `children` means a folder and `url` a
    /// pin. A pin needs a non-empty `url`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: BrowserPinNodeKeys.self)
        let type = try? c.decodeIfPresent(String.self, forKey: .type)
        let isFolder = type.map { $0 == "folder" } ?? c.contains(.children)
        if isFolder {
            self = .folder(try BrowserPinFolder(from: decoder))
            return
        }
        guard type == nil || type == "pin" || type == "bookmark",
              let url = try? c.decode(String.self, forKey: .url),
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "Not a pin")
        }
        self = .pin(BrowserPin(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            url: url,
            title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
            addedAt: (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? BrowserPinTree.unknownDate
        ))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .folder(folder):
            try folder.encode(to: encoder)
        case let .pin(pin):
            var c = encoder.container(keyedBy: BrowserPinNodeKeys.self)
            try c.encode("pin", forKey: .type)
            try c.encode(pin.id, forKey: .id)
            try c.encode(pin.url, forKey: .url)
            try c.encode(pin.title, forKey: .title)
            try c.encode(pin.addedAt, forKey: .addedAt)
        }
    }
}

/// Stage 2's `bookmarks.json`, read once when `spaces.json` is created:
/// `{ "version": 2, "root": { folder } }` with `"type": "bookmark"` nodes.
/// Version 1 (stage 1) was a flat `{ "version": 1, "entries": [...] }` list
/// (or a bare array); it decodes into the root in the order the sidebar
/// showed it, newest first. A node that doesn't decode is skipped and a
/// repeated id dropped.
struct BrowserBookmarksFile: Decodable, Equatable {
    /// The version of the file this was read from.
    var version: Int
    var tree: BrowserPinTree

    private enum CodingKeys: String, CodingKey {
        case version, root
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.root) {
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 2
            let root = (try? c.decode(BrowserPinFolder.self, forKey: .root))
                ?? BrowserPinFolder(id: BrowserPinTree.rootID, name: BrowserPinTree.rootName)
            tree = BrowserPinTree(root: root)
            return
        }
        let list = try JSONList<BrowserPin>(from: decoder)
        version = 1
        // `sorted` is stable: equal dates keep the file's order.
        let ordered = list.entries.sorted { $0.addedAt > $1.addedAt }
        tree = BrowserPinTree(children: ordered.map(BrowserPinNode.pin))
    }
}

// MARK: - Outline

/// The pinned outline (the sidebar's Bookmarks section for now): the
/// visible rows for an expanded set, and where a drag dropped among them
/// lands.
enum BrowserPinOutline {
    struct Row: Equatable {
        var node: BrowserPinNode
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

    static func rows(_ tree: BrowserPinTree, expanded: Set<UUID>) -> [Row] {
        var result: [Row] = []
        func walk(_ folder: BrowserPinFolder, depth: Int) {
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
    /// After the last row: the end of the root. On a pin: nowhere.
    static func destination(for drop: Drop, rows: [Row], tree: BrowserPinTree) -> Destination? {
        switch drop {
        case let .on(row):
            guard rows.indices.contains(row), let folder = rows[row].node.folder else { return nil }
            return Destination(folderID: folder.id, index: folder.children.count)
        case let .above(row):
            if row == rows.count {
                return Destination(folderID: BrowserPinTree.rootID, index: tree.root.children.count)
            }
            guard rows.indices.contains(row) else { return nil }
            return Destination(folderID: rows[row].folderID, index: rows[row].index)
        }
    }
}
