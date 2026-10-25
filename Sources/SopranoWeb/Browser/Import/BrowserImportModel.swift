import Foundation

// The neutral model every import reader produces (Arc, Chrome, Safari,
// Netscape HTML). Pure values: the readers never touch the app's stores; the
// importer maps these onto Spaces, pins, favorites, the archive and History.

/// A link as a source browser stored it: an Arc tab or pin, a Chrome or
/// Netscape bookmark. `url` is kept as the source wrote it.
struct BrowserImportedLink: Sendable, Equatable {
    /// The source's id for the item (Arc's sidebar item UUID), the key of
    /// `BrowserArcImport.favicons`; `nil` when the source has none.
    var sourceID: String?
    var url: String
    /// Never empty: falls back to the URL.
    var title: String
    var addedAt: Date?

    init(sourceID: String? = nil, url: String, title: String, addedAt: Date? = nil) {
        self.sourceID = sourceID
        self.url = url
        self.title = title.isEmpty ? url : title
        self.addedAt = addedAt
    }
}

/// A folder of links: an Arc pinned folder, a Chrome or Netscape folder.
/// `name` may be empty (Arc folders without a title).
struct BrowserImportedFolder: Sendable, Equatable {
    var name: String
    var addedAt: Date?
    var children: [BrowserImportedNode]

    init(name: String, addedAt: Date? = nil, children: [BrowserImportedNode] = []) {
        self.name = name
        self.addedAt = addedAt
        self.children = children
    }
}

/// One entry of an imported tree (pinned tabs, bookmarks).
enum BrowserImportedNode: Sendable, Equatable {
    case folder(BrowserImportedFolder)
    case link(BrowserImportedLink)

    /// Every link below this node, depth first, in order.
    var links: [BrowserImportedLink] {
        switch self {
        case let .link(link): [link]
        case let .folder(folder): folder.children.flatMap(\.links)
        }
    }
}

/// A source profile: Chromium's profile folder name (`Default`, `Profile 3`)
/// as `key`, the name the source shows as `displayName`, and the profile's
/// data folder (where `History` and `Bookmarks` live) when it exists.
struct BrowserImportedProfile: Sendable, Equatable {
    static let defaultKey = "Default"

    var key: String
    var displayName: String
    var directory: URL?

    var isDefault: Bool { key == Self.defaultKey }
}

/// An sRGB color with components as the source stored them (Arc uses
/// extended sRGB, so a component may leave 0…1 slightly).
struct BrowserImportedColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

/// An Arc Space: its pinned tree and its Today (unpinned) tabs.
struct BrowserImportedSpace: Sendable, Equatable {
    /// Arc's Space UUID; what `importedFrom` records so a re-import skips it.
    var sourceID: String
    var name: String
    /// The Space's emoji icon, when it has one.
    var emoji: String?
    /// Arc's built-in icon name (e.g. `planet`) when the Space uses one
    /// instead of an emoji. Not an SF Symbol name.
    var iconName: String?
    /// The theme's mid-tone color, when the Space has a theme.
    var color: BrowserImportedColor?
    /// The `BrowserImportedProfile.key` the Space belongs to.
    var profileKey: String
    var pinned: [BrowserImportedNode]
    /// Today tabs in sidebar order (split views and folders flattened).
    var today: [BrowserImportedLink]
}

/// A profile's favorites (Arc's top apps), in order. Not capped here.
struct BrowserImportedFavorites: Sendable, Equatable {
    var profileKey: String
    var links: [BrowserImportedLink]
}

/// Why the source archived a tab.
enum BrowserImportedArchiveReason: String, Sendable, Equatable {
    case manual
    case auto
    case unknown
}

/// An archived tab. `link.sourceID` is the Arc item id (favicon key).
struct BrowserImportedArchiveItem: Sendable, Equatable {
    var link: BrowserImportedLink
    /// The Space it was archived from; `nil` for Little Arc and unknown sources.
    var spaceSourceID: String?
    var archivedAt: Date
    var reason: BrowserImportedArchiveReason
}

/// A history record. Chromium gives one per visit (`visitCount` 1); Safari's
/// export gives one per URL with its latest visit and how many visits it
/// stands for.
struct BrowserImportedVisit: Sendable, Equatable {
    var url: String
    var title: String
    var visitedAt: Date
    /// The user typed the URL (Chromium's `TYPED` transition).
    var typed: Bool
    var visitCount: Int

    init(url: String, title: String, visitedAt: Date, typed: Bool = false, visitCount: Int = 1) {
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.typed = typed
        self.visitCount = max(1, visitCount)
    }

    /// The URL schemes worth importing into History (no `chrome://`,
    /// `arc://`, `about:`, `data:` or `javascript:` entries).
    static func isImportable(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        switch url[..<colon].lowercased() {
        case "http", "https", "file": return true
        default: return false
        }
    }
}

/// An Arc link-routing ("Air Traffic Control") rule: links from other apps
/// whose URL matches open in `destination`.
struct BrowserImportedRoutingRule: Sendable, Equatable {
    enum Match: Sendable, Equatable {
        /// The URL contains `value`.
        case contains
        /// The URL equals `value`.
        case equals
    }

    enum Destination: Sendable, Equatable {
        /// A Space; `nil` means the most recently used one.
        case space(sourceID: String?)
        /// Arc's Little Arc window.
        case littleArc
        /// A profile; `nil` means the most recently used one.
        case profile(key: String?)
    }

    var match: Match
    var value: String
    var destination: Destination
}

/// Why a reader could not produce anything.
enum BrowserImportError: Error, Equatable, CustomStringConvertible {
    /// The source's main file is missing (Arc not installed, wrong folder).
    case missingFile(URL)
    /// The file exists but is not in the expected format.
    case unreadable(URL, String)
    /// `ditto` could not expand the archive.
    case unzipFailed(String)

    var description: String {
        switch self {
        case let .missingFile(url): "Missing \(url.path)"
        case let .unreadable(url, reason): "Cannot read \(url.path): \(reason)"
        case let .unzipFailed(reason): "Cannot expand the archive: \(reason)"
        }
    }
}
