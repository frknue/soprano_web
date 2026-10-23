import AppKit

/// What the page's isolated-world `contextmenu` listener saw under the
/// pointer. It posts before WebKit asks the UI process to show the menu, so
/// `BrowserWebView.willOpenMenu(_:with:)` finds it already set.
struct BrowserContextMenuTarget: Equatable {
    var link: URL?
    var image: URL?
    var selection: String?
    var capturedAt: Date

    init(link: URL? = nil, image: URL? = nil, selection: String? = nil, capturedAt: Date = Date()) {
        self.link = link
        self.image = image
        self.selection = selection
        self.capturedAt = capturedAt
    }

    /// Parses the `contextMenu` page message; nil for anything malformed.
    init?(body: [String: Any], now: Date = Date()) {
        func url(_ key: String) -> URL? {
            guard let value = body[key] as? String, !value.isEmpty,
                  let url = URL(string: value), url.scheme != nil
            else { return nil }
            return url
        }
        let selection = (body["selection"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(link: url("link"), image: url("image"), selection: selection, capturedAt: now)
    }

    /// A target older than this belongs to an earlier right-click (the page
    /// cancelled that menu, or this menu came from a view without a DOM).
    static let freshness: TimeInterval = 2

    func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(capturedAt) <= Self.freshness && date >= capturedAt
    }
}

/// One of WebKit's context menu items, by the `NSMenuItem.identifier`
/// strings WebKit assigns (logged from real menus with
/// `SopranoWeb snapshot --context-menu <selector>`).
enum WebKitMenuItem {
    static let openLink = "WKMenuItemIdentifierOpenLink"
    static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
    static let downloadLinkedFile = "WKMenuItemIdentifierDownloadLinkedFile"
    static let copyLink = "WKMenuItemIdentifierCopyLink"
    static let openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
    static let downloadImage = "WKMenuItemIdentifierDownloadImage"
    static let copyImage = "WKMenuItemIdentifierCopyImage"
    static let openMediaInNewWindow = "WKMenuItemIdentifierOpenMediaInNewWindow"
    static let openFrameInNewWindow = "WKMenuItemIdentifierOpenFrameInNewWindow"
    static let searchWeb = "WKMenuItemIdentifierSearchWeb"
}

/// The browser's own context menu commands.
enum BrowserContextMenuAction: Equatable {
    case openInNewTab(URL)
    case openInBackgroundTab(URL)
    case openImageInNewTab(URL)
    case download(URL)
    case search(query: String, url: URL)
}

/// The menu after the transformation, as positions in WebKit's item list.
enum BrowserContextMenuEntry: Equatable {
    /// WebKit's item at this index, unchanged.
    case keep(Int)
    /// WebKit's item at this index with a new title (its action still opens
    /// the page through `createWebViewWith`, which makes a tab).
    case retitle(Int, String)
    case action(BrowserContextMenuAction, title: String)
}

enum BrowserContextMenu {
    /// Rewrites WebKit's menu, given each item's identifier (nil for
    /// separators and items without one) and their titles, into the
    /// browser's menu. Pure: same identifiers and target, same menu.
    static func transform(
        identifiers: [String?],
        titles: [String],
        target: BrowserContextMenuTarget?,
        searchEngine: SearchEngine
    ) -> [BrowserContextMenuEntry] {
        var entries: [BrowserContextMenuEntry] = []
        for (index, identifier) in identifiers.enumerated() {
            let title = titles.indices.contains(index) ? titles[index] : ""
            switch identifier {
            case WebKitMenuItem.openLinkInNewWindow:
                if let link = target?.link {
                    entries.append(.action(.openInNewTab(link), title: "Open Link in New Tab"))
                    entries.append(.action(.openInBackgroundTab(link), title: "Open Link in Background Tab"))
                } else {
                    entries.append(.retitle(index, "Open Link in New Tab"))
                }
            case WebKitMenuItem.downloadLinkedFile:
                if let link = target?.link {
                    entries.append(.action(.download(link), title: title))
                } else {
                    entries.append(.keep(index))
                }
            case WebKitMenuItem.openImageInNewWindow:
                if let image = target?.image {
                    entries.append(.action(.openImageInNewTab(image), title: "Open Image in New Tab"))
                } else {
                    entries.append(.retitle(index, "Open Image in New Tab"))
                }
            case WebKitMenuItem.downloadImage:
                if let image = target?.image {
                    entries.append(.action(.download(image), title: title))
                } else {
                    entries.append(.keep(index))
                }
            case WebKitMenuItem.openMediaInNewWindow, WebKitMenuItem.openFrameInNewWindow:
                entries.append(.retitle(index, title.replacingOccurrences(of: "New Window", with: "New Tab")))
            case WebKitMenuItem.searchWeb:
                if let query = target?.selection.map(searchQuery), !query.isEmpty,
                   let url = searchEngine.searchURL(for: query)
                {
                    entries.append(.action(
                        .search(query: query, url: url),
                        title: searchTitle(query: query, engine: searchEngine)
                    ))
                } else {
                    entries.append(.keep(index))
                }
            default:
                entries.append(.keep(index))
            }
        }
        return entries
    }

    /// The selection as a search query: whitespace runs collapse to one
    /// space and the ends are trimmed.
    static func searchQuery(_ selection: String) -> String {
        selection
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// `Search with DuckDuckGo for “query”`, the query cut to
    /// `maxQueryLength` characters with an ellipsis.
    static func searchTitle(query: String, engine: SearchEngine, maxQueryLength: Int = 30) -> String {
        let shown = query.count > maxQueryLength
            ? String(query.prefix(maxQueryLength)).trimmingCharacters(in: .whitespaces) + "…"
            : query
        return "Search with \(engine.name) for “\(shown)”"
    }
}
