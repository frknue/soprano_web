import CryptoKit
import Foundation

/// Everything the Arc reader found, except History (read per profile with
/// `BrowserArcImportReader.readHistory`, it is large).
struct BrowserArcImport: Sendable, Equatable {
    /// Every profile a Space or a favorites list uses, in first-use order,
    /// then the other profiles that have a History database (Arc's own
    /// `__ARC_SYSTEM_PROFILE` never).
    var profiles: [BrowserImportedProfile]
    /// In Arc's order.
    var spaces: [BrowserImportedSpace]
    /// One entry per profile with favorites.
    var favorites: [BrowserImportedFavorites]
    /// Archived tabs with a URL, oldest first, as Arc stores them.
    var archive: [BrowserImportedArchiveItem]
    var routingRules: [BrowserImportedRoutingRule]
    /// `StorableLinkRouting.json`'s `defaultDestination`: where Arc sends
    /// links no rule matches (Little Arc, or a Space); nil when absent.
    var defaultLinkDestination: BrowserImportedRoutingRule.Destination? = nil
    /// Item `sourceID` (pins, Today tabs, favorites, archive) → its cached
    /// favicon, a PNG file in Arc's support folder.
    var favicons: [String: URL]
    /// Profile key → its Chromium `History` database, for profiles that have one.
    var historyFiles: [String: URL]
}

/// Reads Arc's support folder (`~/Library/Application Support/Arc`) without
/// writing to it: `StorableSidebar.json` (Spaces, pinned trees, Today tabs,
/// favorites), `StorableArchiveItems.json`, `StorableLinkRouting.json`, the
/// favicon caches and, per profile, `User Data/<profile>/History`.
///
/// Arc's files are Swift `JSONEncoder` output: a dictionary whose keys are
/// not strings is an array of alternating keys and values, an enum is
/// `{"case": {"_0": payload}}` (or `{"case": {}}`, or a bare string for raw
/// values), and dates are seconds since 2001-01-01.
struct BrowserArcImportReader: Sendable {
    /// The `Local State` name of Arc's internal profile, never imported.
    static let systemProfileName = "__ARC_SYSTEM_PROFILE"

    /// `~/Library/Application Support/Arc`.
    static var defaultSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
    }

    let supportDirectory: URL

    init(supportDirectory: URL = BrowserArcImportReader.defaultSupportDirectory) {
        self.supportDirectory = supportDirectory
    }

    var sidebarURL: URL { supportDirectory.appendingPathComponent("StorableSidebar.json") }
    var userDataDirectory: URL { supportDirectory.appendingPathComponent("User Data", isDirectory: true) }

    /// Arc's sidebar file exists (what File ▸ Import offers Arc on).
    var isAvailable: Bool { FileManager.default.fileExists(atPath: sidebarURL.path) }

    /// Reads the sidebar (throws when it is missing or not Arc's format) and,
    /// tolerantly, the archive, link routing and favicon caches: a missing or
    /// damaged one of those yields no entries.
    func read() throws -> BrowserArcImport {
        let root = try Self.jsonObject(at: sidebarURL)
        guard let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let container = Self.spacesContainer(containers)
        else {
            throw BrowserImportError.unreadable(sidebarURL, "no sidebar container with spaces")
        }

        var items: [String: ArcItem] = [:]
        for value in ArcJSON.values(container["items"]) {
            if let item = ArcItem(value) { items[item.id] = item }
        }
        let sidebar = ArcSidebar(items: items)

        var profileKeys: [String] = []
        func use(_ key: String) {
            if !profileKeys.contains(key) { profileKeys.append(key) }
        }

        var spaces: [BrowserImportedSpace] = []
        for value in ArcJSON.values(container["spaces"]) {
            guard let space = Self.space(value, sidebar: sidebar) else { continue }
            use(space.profileKey)
            spaces.append(space)
        }

        var favorites: [BrowserImportedFavorites] = []
        for pair in ArcJSON.pairs(container["topAppsContainerIDs"]) {
            guard let containerID = pair.value as? String else { continue }
            let key = ArcJSON.profileKey(pair.key) ?? BrowserImportedProfile.defaultKey
            let links = sidebar.children(of: containerID).flatMap(\.links)
            guard !links.isEmpty else { continue }
            use(key)
            if let index = favorites.firstIndex(where: { $0.profileKey == key }) {
                favorites[index].links += links
            } else {
                favorites.append(BrowserImportedFavorites(profileKey: key, links: links))
            }
        }

        let discovered = BrowserChromeBookmarksReader.profiles(userDataDirectory: userDataDirectory)
            .filter { $0.displayName != Self.systemProfileName }
        var profiles = profileKeys.map { key in
            let found = discovered.first { $0.key == key }
            return BrowserImportedProfile(key: key, displayName: found?.displayName ?? key, directory: found?.directory)
        }
        for profile in discovered where !profileKeys.contains(profile.key) {
            guard let directory = profile.directory,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("History").path)
            else { continue }
            profiles.append(profile)
        }
        var historyFiles: [String: URL] = [:]
        for profile in profiles {
            guard let file = profile.directory?.appendingPathComponent("History"),
                  FileManager.default.fileExists(atPath: file.path)
            else { continue }
            historyFiles[profile.key] = file
        }

        let archive = readArchive()
        let routing = readRoutingRules()
        var itemIDs = spaces.flatMap { space in
            space.pinned.flatMap(\.links).map(\.sourceID) + space.today.map(\.sourceID)
        }
        itemIDs += favorites.flatMap { $0.links.map(\.sourceID) }
        itemIDs += archive.map(\.link.sourceID)

        return BrowserArcImport(
            profiles: profiles,
            spaces: spaces,
            favorites: favorites,
            archive: archive,
            routingRules: routing.rules,
            defaultLinkDestination: routing.defaultDestination,
            favicons: favicons(for: itemIDs.compactMap { $0 }),
            historyFiles: historyFiles
        )
    }

    /// Streams one profile's History (`User Data/<profileKey>/History`); see
    /// `BrowserChromiumHistoryReader.read`.
    func readHistory(
        profileKey: String,
        since: Date? = nil,
        batchSize: Int = 5_000,
        _ body: ([BrowserImportedVisit]) throws -> Void
    ) throws {
        let file = userDataDirectory
            .appendingPathComponent(profileKey, isDirectory: true)
            .appendingPathComponent("History")
        try BrowserChromiumHistoryReader(fileURL: file).read(since: since, batchSize: batchSize, body)
    }

    /// `StorableArchiveItems.json`, else the newest dated
    /// `StorableArchiveItems.<date>.json` backup. (`StorableArchive.json`
    /// and its backups are only the auto-archive settings.)
    var archiveURL: URL? {
        let main = supportDirectory.appendingPathComponent("StorableArchiveItems.json")
        if FileManager.default.fileExists(atPath: main.path) { return main }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: supportDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("StorableArchiveItems.") && $0.hasSuffix(".json") }
            .max()
            .map { supportDirectory.appendingPathComponent($0) }
    }

    /// The name of an item's file in Arc's favicon caches: the lowercase hex
    /// MD5 of its upper-case UUID.
    static func faviconFileName(for itemID: String) -> String {
        Insecure.MD5.hash(data: Data(itemID.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Private

    private static let faviconFolders = ["SidebarItemsFaviconCache", "ArchiveItemsFaviconCache"]

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw BrowserImportError.missingFile(url)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserImportError.unreadable(url, "not a JSON object")
        }
        return object
    }

    /// `containers[1]` (Arc's; `containers[0]` is `{"global": {}}`), else
    /// the first container with spaces.
    private static func spacesContainer(_ containers: [Any]) -> [String: Any]? {
        if containers.count > 1, let container = containers[1] as? [String: Any], container["spaces"] != nil {
            return container
        }
        return containers.lazy.compactMap { $0 as? [String: Any] }.first { $0["spaces"] != nil }
    }

    private static func space(_ any: Any, sidebar: ArcSidebar) -> BrowserImportedSpace? {
        guard let json = any as? [String: Any], let id = ArcJSON.string(json["id"]) else { return nil }
        var containerPairs = ArcJSON.pairs(json["containerIDs"])
        if containerPairs.isEmpty { containerPairs = ArcJSON.pairs(json["newContainerIDs"]) }
        var pinned: [BrowserImportedNode] = []
        var today: [BrowserImportedLink] = []
        var todaySplits: [[Int]] = []
        for pair in containerPairs {
            guard let containerID = pair.value as? String else { continue }
            switch ArcJSON.enumCase(pair.key)?.name ?? "" {
            case "pinned": pinned += sidebar.children(of: containerID)
            case "unpinned":
                let found = sidebar.todayLinks(of: containerID)
                todaySplits += found.splits.map { split in split.map { $0 + today.count } }
                today += found.links
            default: continue
            }
        }

        let customInfo = json["customInfo"] as? [String: Any]
        let iconType = customInfo?["iconType"] as? [String: Any]
        let emoji = ArcJSON.string(iconType?["emoji_v2"])
            ?? (iconType?["emoji"] as? NSNumber)
            .flatMap { Unicode.Scalar($0.uint32Value) }
            .map { String(Character($0)) }
        let theme = customInfo?["windowTheme"] as? [String: Any]
        let palette = theme?["primaryColorPalette"] as? [String: Any]
        let color = ArcJSON.color(palette?["midTone"]) ?? ArcJSON.firstColor(in: theme?["background"])

        return BrowserImportedSpace(
            sourceID: id,
            name: ArcJSON.string(json["title"]) ?? "Space",
            emoji: emoji,
            iconName: ArcJSON.string(iconType?["icon"]),
            color: color,
            profileKey: ArcJSON.profileKey(json["profile"]) ?? BrowserImportedProfile.defaultKey,
            pinned: pinned,
            today: today,
            todaySplits: todaySplits
        )
    }

    private func readArchive() -> [BrowserImportedArchiveItem] {
        guard let url = archiveURL, let root = try? Self.jsonObject(at: url) else { return [] }
        return ArcJSON.values(root["items"]).compactMap { (value: Any) -> BrowserImportedArchiveItem? in
            guard let entry = value as? [String: Any],
                  let item = ArcItem(entry["sidebarItem"]),
                  let link = item.link
            else { return nil }
            guard let archivedAt = ArcJSON.date(entry["archivedAt"]) ?? item.createdAt else { return nil }
            let reason = ArcJSON.enumCase(entry["reason"])
                .flatMap { BrowserImportedArchiveReason(rawValue: $0.name) } ?? .unknown
            var spaceID: String?
            if let source = ArcJSON.enumCase(entry["source"]), source.name == "space" {
                spaceID = ArcJSON.string(ArcJSON.first(source.payload))
            }
            return BrowserImportedArchiveItem(link: link, spaceSourceID: spaceID, archivedAt: archivedAt, reason: reason)
        }
    }

    private func readRoutingRules() -> (rules: [BrowserImportedRoutingRule], defaultDestination: BrowserImportedRoutingRule.Destination?) {
        let url = supportDirectory.appendingPathComponent("StorableLinkRouting.json")
        guard FileManager.default.fileExists(atPath: url.path), let root = try? Self.jsonObject(at: url) else {
            return ([], nil)
        }
        var rules: [BrowserImportedRoutingRule] = []
        for case let rule as [String: Any] in root["rules"] as? [Any] ?? [] {
            guard let destination = Self.destination(rule["destination"]) else { continue }
            for case let component as [String: Any] in rule["sourceComponents"] as? [Any] ?? [] {
                guard let type = ArcJSON.enumCase(component["componentType"]), type.name == "urlMatch",
                      let payload = type.payload as? [String: Any],
                      let value = ArcJSON.string(payload["_1"]),
                      let style = ArcJSON.enumCase(payload["_0"])?.name
                else { continue }
                let match: BrowserImportedRoutingRule.Match
                switch style {
                case "contains": match = .contains
                case "equals", "matches", "exact", "is": match = .equals
                case "prefix", "startsWith", "beginsWith", "hasPrefix": match = .prefix
                default: continue
                }
                rules.append(BrowserImportedRoutingRule(match: match, value: value, destination: destination))
            }
        }
        return (rules, Self.destination(root["defaultDestination"]))
    }

    /// `{"space": {"_0": {"mostRecent": {}}}}`, a Space id inside the
    /// `space` payload, `{"littleArc": …}` or `{"profile": {"_0": …}}`.
    private static func destination(_ any: Any?) -> BrowserImportedRoutingRule.Destination? {
        guard let destination = ArcJSON.enumCase(any) else { return nil }
        let inner = ArcJSON.first(destination.payload)
        switch destination.name {
        case "space":
            if ArcJSON.enumCase(inner)?.name == "mostRecent" { return .space(sourceID: nil) }
            return .space(sourceID: ArcJSON.firstUUID(in: inner))
        case "littleArc":
            return .littleArc
        case "profile":
            return .profile(key: ArcJSON.profileKey(inner))
        default:
            return nil
        }
    }

    private func favicons(for itemIDs: [String]) -> [String: URL] {
        var files: [String: URL] = [:]
        for folderName in Self.faviconFolders {
            let folder = supportDirectory.appendingPathComponent(folderName, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where files[name] == nil {
                files[name] = folder.appendingPathComponent(name)
            }
        }
        guard !files.isEmpty else { return [:] }
        var result: [String: URL] = [:]
        for id in itemIDs {
            if let file = files[Self.faviconFileName(for: id)] { result[id] = file }
        }
        return result
    }
}

/// One entry of Arc's flat `items` map.
private struct ArcItem {
    var id: String
    var title: String?
    /// The `data` case: `tab`, `list`, `itemContainer`, `splitView`, `easel`, …
    var kind: String
    var payload: [String: Any]
    var childrenIDs: [String]
    var createdAt: Date?

    init?(_ any: Any?) {
        guard let json = any as? [String: Any],
              let id = ArcJSON.string(json["id"]),
              let data = ArcJSON.enumCase(json["data"])
        else { return nil }
        self.id = id
        title = ArcJSON.string(json["title"])
        kind = data.name
        payload = data.payload as? [String: Any] ?? [:]
        childrenIDs = (json["childrenIds"] as? [Any] ?? []).compactMap { $0 as? String }
        createdAt = ArcJSON.date(json["createdAt"])
    }

    /// A tab with a saved URL; its title is the user's title, else the page
    /// title, else the URL.
    var link: BrowserImportedLink? {
        guard kind == "tab", let url = ArcJSON.string(payload["savedURL"]) else { return nil }
        let title = self.title ?? ArcJSON.string(payload["savedTitle"]) ?? url
        return BrowserImportedLink(sourceID: id, url: url, title: title, addedAt: createdAt)
    }
}

/// Builds trees from the flat item map along `childrenIds`.
private struct ArcSidebar {
    let items: [String: ArcItem]

    /// The tree under a container (a Space's pinned or unpinned container,
    /// a favorites container): lists become folders, tabs links, split views
    /// and other containers are flattened into their tabs, items without a
    /// URL are dropped. Pins are saved links, not open tabs, so a pinned
    /// split view's tabs stay separate pins.
    func children(of containerID: String) -> [BrowserImportedNode] {
        var visited: Set<String> = [containerID]
        return nodes(items[containerID]?.childrenIDs ?? [], visited: &visited)
    }

    /// A Today container's tabs in sidebar order (folders and other
    /// containers flattened, as `children(of:)` gives them) and its split
    /// views, each as the indices of its tabs in that list: the first
    /// `BrowserSplit.maximumPanes` of them (a split view nested in another
    /// counts as its tabs); one with fewer than two tabs is no split.
    func todayLinks(of containerID: String) -> (links: [BrowserImportedLink], splits: [[Int]]) {
        var visited: Set<String> = [containerID]
        var links: [BrowserImportedLink] = []
        var splits: [[Int]] = []
        collect(items[containerID]?.childrenIDs ?? [], visited: &visited, links: &links, splits: &splits, inSplit: false)
        return (links, splits)
    }

    private func collect(
        _ ids: [String],
        visited: inout Set<String>,
        links: inout [BrowserImportedLink],
        splits: inout [[Int]],
        inSplit: Bool
    ) {
        for id in ids {
            guard visited.insert(id).inserted, let item = items[id] else { continue }
            switch item.kind {
            case "tab":
                if let link = item.link { links.append(link) }
            case "splitView" where !inSplit:
                let start = links.count
                collect(item.childrenIDs, visited: &visited, links: &links, splits: &splits, inSplit: true)
                let panes = Array((start..<links.count).prefix(BrowserSplit.maximumPanes))
                if panes.count >= 2 { splits.append(panes) }
            default:
                collect(item.childrenIDs, visited: &visited, links: &links, splits: &splits, inSplit: inSplit)
            }
        }
    }

    private func nodes(_ ids: [String], visited: inout Set<String>) -> [BrowserImportedNode] {
        var result: [BrowserImportedNode] = []
        for id in ids {
            guard visited.insert(id).inserted, let item = items[id] else { continue }
            switch item.kind {
            case "tab":
                if let link = item.link { result.append(.link(link)) }
            case "list":
                let children = nodes(item.childrenIDs, visited: &visited)
                result.append(.folder(BrowserImportedFolder(name: item.title ?? "", addedAt: item.createdAt, children: children)))
            default:
                result += nodes(item.childrenIDs, visited: &visited)
            }
        }
        return result
    }
}

/// Helpers for Swift `JSONEncoder` output read through `JSONSerialization`.
private enum ArcJSON {
    /// A dictionary encoded as `[key0, value0, key1, value1, …]` (an odd
    /// trailing key is dropped); a JSON object yields its entries unordered.
    static func pairs(_ any: Any?) -> [(key: Any, value: Any)] {
        if let array = any as? [Any] {
            var result: [(key: Any, value: Any)] = []
            result.reserveCapacity(array.count / 2)
            var index = 0
            while index + 1 < array.count {
                result.append((key: array[index], value: array[index + 1]))
                index += 2
            }
            return result
        }
        if let object = any as? [String: Any] {
            return object.map { (key: $0.key as Any, value: $0.value) }
        }
        return []
    }

    static func values(_ any: Any?) -> [Any] {
        pairs(any).map { $0.value }
    }

    /// An enum value: `"name"`, `{"name": {}}` or `{"name": payload}`.
    static func enumCase(_ any: Any?) -> (name: String, payload: Any?)? {
        if let name = any as? String { return (name, nil) }
        guard let object = any as? [String: Any], object.count == 1, let entry = object.first else { return nil }
        return (entry.key, entry.value)
    }

    /// An associated value's first element (`{"_0": value}`).
    static func first(_ payload: Any?) -> Any? {
        (payload as? [String: Any])?["_0"]
    }

    /// A non-empty string.
    static func string(_ any: Any?) -> String? {
        guard let string = any as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Seconds since 2001-01-01.
    static func date(_ any: Any?) -> Date? {
        (any as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    }

    /// `{"default": {}}` → `Default`; `{"custom": {"_0": {"directoryBasename": "Profile 3"}}}` → `Profile 3`.
    static func profileKey(_ any: Any?) -> String? {
        guard let profile = enumCase(any) else { return nil }
        switch profile.name {
        case "default": return BrowserImportedProfile.defaultKey
        case "custom": return string((first(profile.payload) as? [String: Any])?["directoryBasename"])
        default: return nil
        }
    }

    /// `{"red", "green", "blue", "alpha"?, "colorSpace"?}`.
    static func color(_ any: Any?) -> BrowserImportedColor? {
        guard let object = any as? [String: Any],
              let red = object["red"] as? NSNumber,
              let green = object["green"] as? NSNumber,
              let blue = object["blue"] as? NSNumber
        else { return nil }
        return BrowserImportedColor(
            red: red.doubleValue,
            green: green.doubleValue,
            blue: blue.doubleValue,
            alpha: (object["alpha"] as? NSNumber)?.doubleValue ?? 1
        )
    }

    /// The first opaque color found depth first (a theme background's
    /// single color or first gradient color).
    static func firstColor(in any: Any?, depth: Int = 0) -> BrowserImportedColor? {
        guard depth < 12 else { return nil }
        if let found = color(any), found.alpha > 0 { return found }
        if let object = any as? [String: Any] {
            for key in object.keys.sorted() {
                if let color = firstColor(in: object[key], depth: depth + 1) { return color }
            }
        } else if let array = any as? [Any] {
            for element in array {
                if let color = firstColor(in: element, depth: depth + 1) { return color }
            }
        }
        return nil
    }

    /// The first UUID-shaped string found depth first.
    static func firstUUID(in any: Any?, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let string = any as? String { return UUID(uuidString: string) != nil ? string : nil }
        if let object = any as? [String: Any] {
            for key in object.keys.sorted() {
                if let id = firstUUID(in: object[key], depth: depth + 1) { return id }
            }
        } else if let array = any as? [Any] {
            for element in array {
                if let id = firstUUID(in: element, depth: depth + 1) { return id }
            }
        }
        return nil
    }
}
