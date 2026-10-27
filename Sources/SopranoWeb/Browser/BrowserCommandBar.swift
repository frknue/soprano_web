import Foundation

/// How the Command Bar opened: ⌘T (Enter opens a new Today tab), ⌘L (the
/// current address, Enter navigates the selected tab) or ⇧⌘P (`/`
/// actions).
enum BrowserCommandBarMode: String, Equatable, Sendable {
    case newTab
    case editCurrent
    case actions
}

/// Settings pages the Command Bar opens (Settings, and its sheets).
enum BrowserSettingsPage: String, CaseIterable, Sendable {
    case general
    case searchEngines = "search-engines"
    case shortcuts
    case websites
    case websiteData = "website-data"

    var title: String {
        switch self {
        case .general: "Settings"
        case .searchEngines: "Search Engines"
        case .shortcuts: "Keyboard Shortcuts"
        case .websites: "Websites"
        case .websiteData: "Website Data"
        }
    }

    var synonyms: [String] {
        switch self {
        case .general: ["preferences", "theme", "homepage", "downloads"]
        case .searchEngines: ["keywords", "site search", "default search"]
        case .shortcuts: ["keys", "remap", "hotkeys"]
        case .websites: ["permissions", "camera", "microphone", "notifications"]
        case .websiteData: ["cookies", "storage"]
        }
    }
}

/// One Command Bar row and what choosing it does.
struct BrowserCommandBarRow: Equatable, Sendable {
    enum Kind: String, Sendable {
        case open
        case search
        case tab
        case pin
        case favorite
        case history
        case space
        case action
        case settings
    }

    enum Target: Hashable, Sendable {
        /// An address: a new Today tab (⌘T) or the selected tab (⌘L).
        case url(String)
        case search(engine: BrowserSearchEngineID, query: String)
        /// An open tab of the window (any Space; selecting it switches).
        case tab(UUID)
        case pin(UUID)
        case favorite(UUID)
        case space(UUID)
        case command(BrowserCommandID)
        case settings(BrowserSettingsPage)
        /// ⌘T's Return on an empty query: a start-page Today tab.
        case startPage
    }

    var kind: Kind
    var title: String
    /// The address (SF Mono), the Space of a tab in another Space, the
    /// engine of a search.
    var detail: String = ""
    /// A `/` action's shortcut, as shown.
    var shortcut: String = ""
    var symbol: String = ""
    var target: Target
}

struct BrowserCommandBarGroup: Equatable, Sendable {
    /// Empty for the first group (what Enter opens).
    var title: String
    var rows: [BrowserCommandBarRow]
}

/// What the Command Bar searches, gathered by the window.
struct BrowserCommandBarInput: Sendable {
    struct Tab: Equatable, Sendable {
        var id: UUID
        var title: String
        var url: String
        /// Set for a tab of another Space than the window's current one.
        var otherSpace: String?
    }

    struct Space: Equatable, Sendable {
        var id: UUID
        var name: String
        var isCurrent: Bool
    }

    struct Action: Equatable, Sendable {
        var id: BrowserCommandID
        var title: String
        var synonyms: [String]
        var shortcut: String
        var symbol: String
    }

    var query: String
    var mode: BrowserCommandBarMode = .newTab
    /// The site-search chip's engine.
    var siteSearch: BrowserSearchEngineID?
    /// The window's tabs, most recently selected first (the selected one
    /// left out).
    var tabs: [Tab] = []
    /// The current Space's pins.
    var pins: [BrowserPin] = []
    /// The current Space's favorites.
    var favorites: [BrowserPin] = []
    /// History's candidates for the query (a private window's in-memory
    /// visits).
    var history: [BrowserHistoryPage] = []
    var spaces: [Space] = []
    /// The registry's enabled commands that have a Command Bar row.
    var actions: [Action] = []
    var settingsPages: [BrowserSettingsPage] = BrowserSettingsPage.allCases
    var searchEngines: BrowserSearchEngines = .default
}

/// The Command Bar's results, pure: grouped rows for a query.
enum BrowserCommandBarEngine {
    static let recentTabRows = 6
    static let tabRows = 4
    static let pinRows = 4
    static let historyRows = 5
    static let spaceRows = 3
    static let actionRows = 3
    static let slashActionRows = 12
    static let settingsRows = 2

    static func groups(for input: BrowserCommandBarInput) -> [BrowserCommandBarGroup] {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = input.siteSearch, let engine = input.searchEngines.engine(id: id) {
            guard !query.isEmpty else { return [] }
            return [BrowserCommandBarGroup(title: "", rows: [searchRow(engine: engine, query: query)])]
        }
        if query.hasPrefix("/") {
            let term = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            let rows = rankedActions(input.actions, term: term, minimumTier: .substring)
                .prefix(slashActionRows)
            return rows.isEmpty ? [] : [BrowserCommandBarGroup(title: "Actions", rows: Array(rows))]
        }
        guard !query.isEmpty else {
            // ⌘T: Return opens a start-page Today tab; the recent tabs
            // follow. ⌘L on an empty field (a start page) offers nothing,
            // so Return does nothing.
            guard input.mode == .newTab else { return [] }
            let newTab = BrowserCommandBarRow(
                kind: .open, title: "New Tab", detail: "Start page", symbol: "plus", target: .startPage
            )
            var groups = [BrowserCommandBarGroup(title: "", rows: [newTab])]
            let rows = input.tabs.prefix(recentTabRows).map(tabRow)
            if !rows.isEmpty { groups.append(BrowserCommandBarGroup(title: "Recent Tabs", rows: rows)) }
            return groups
        }

        var groups = [BrowserCommandBarGroup(title: "", rows: [defaultRow(query: query, engines: input.searchEngines)])]
        let matcher = AddressQueryMatcher(query: query)

        let tabs = input.tabs.enumerated()
            .compactMap { index, tab -> (Int, AddressQueryMatcher.Tier, BrowserCommandBarInput.Tab)? in
                matcher.tier(url: tab.url, title: tab.title).map { (index, $0, tab) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(tabRows)
            .map { tabRow($0.2) }
        append("Open Tabs", Array(tabs), to: &groups)

        let tabKeys = Set(input.tabs.map { AddressURLText.key($0.url) })
        let favoriteKeys = Dictionary(
            input.favorites.map { (AddressURLText.key($0.url), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pinKeys = Dictionary(input.pins.map { (AddressURLText.key($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        let pages = AddressSuggestionEngine.rankedPages(
            query: query,
            history: input.history,
            pins: input.favorites + input.pins
        )
        var pinRows: [BrowserCommandBarRow] = []
        var historyRows: [BrowserCommandBarRow] = []
        for page in pages {
            let key = AddressURLText.key(page.url)
            let display = AddressURLText.display(page.url)
            let title = page.title.isEmpty ? display : page.title
            if page.isPinned {
                if let favorite = favoriteKeys[key] {
                    pinRows.append(BrowserCommandBarRow(
                        kind: .favorite, title: favorite.displayTitle, detail: display, symbol: "star",
                        target: .favorite(favorite.id)
                    ))
                } else if let pin = pinKeys[key] {
                    pinRows.append(BrowserCommandBarRow(
                        kind: .pin, title: pin.displayTitle, detail: display, symbol: "pin", target: .pin(pin.id)
                    ))
                }
            } else if !tabKeys.contains(key) {
                historyRows.append(BrowserCommandBarRow(
                    kind: .history, title: title, detail: display, symbol: "clock", target: .url(page.url)
                ))
            }
        }
        append("Pinned and Favorites", Array(pinRows.prefix(Self.pinRows)), to: &groups)
        append("History", Array(historyRows.prefix(Self.historyRows)), to: &groups)

        let spaces = input.spaces.enumerated()
            .compactMap { index, space -> (Int, TextTier, BrowserCommandBarInput.Space)? in
                textTier(query, in: [space.name]).map { (index, $0, space) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(spaceRows)
            .map { _, _, space in
                BrowserCommandBarRow(
                    kind: .space,
                    title: space.name,
                    detail: space.isCurrent ? "Current Space" : "Switch to Space",
                    symbol: "square.stack",
                    target: .space(space.id)
                )
            }
        append("Spaces", Array(spaces), to: &groups)

        // Without "/", actions show only for a strong match.
        if query.count >= 2 {
            append("Actions", Array(rankedActions(input.actions, term: query, minimumTier: .wordStart).prefix(actionRows)), to: &groups)
            let pages = input.settingsPages.enumerated()
                .compactMap { index, page -> (Int, TextTier, BrowserSettingsPage)? in
                    textTier(query, in: [page.title] + page.synonyms).map { (index, $0, page) }
                }
                .filter { $0.1 >= .wordStart }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(settingsRows)
                .map { _, _, page in
                    BrowserCommandBarRow(
                        kind: .settings, title: page.title, detail: "Settings", symbol: "gearshape",
                        target: .settings(page)
                    )
                }
            append("Settings", Array(pages), to: &groups)
        }
        return groups
    }

    /// Return without touching the arrows: "keyword query" searches that
    /// engine, an address opens, anything else searches the default engine.
    static func defaultRow(query: String, engines: BrowserSearchEngines) -> BrowserCommandBarRow {
        if let keyword = engines.resolve(query) {
            return searchRow(engine: keyword.engine, query: keyword.query)
        }
        if let url = BrowserAddressResolver.address(for: query) {
            let address = url.absoluteString
            return BrowserCommandBarRow(
                kind: .open,
                title: AddressURLText.display(address),
                detail: "Open",
                symbol: "globe",
                target: .url(address)
            )
        }
        return searchRow(engine: engines.defaultEngine, query: query)
    }

    static func searchRow(engine: BrowserSearchEngine, query: String) -> BrowserCommandBarRow {
        BrowserCommandBarRow(
            kind: .search,
            title: "Search \(engine.name) for “\(query)”",
            detail: engine.name,
            symbol: "magnifyingglass",
            target: .search(engine: engine.id, query: query)
        )
    }

    /// Tab on the field's text enters site search: an engine's keyword
    /// ("w"), or the start of its name ("wiki") when only one engine has
    /// it.
    static func siteSearchEngine(for text: String, engines: BrowserSearchEngines) -> BrowserSearchEngine? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if let engine = engines.engine(forKeyword: trimmed) {
            return engine
        }
        guard trimmed.count >= 2 else { return nil }
        let folded = fold(trimmed)
        let matches = engines.all.filter { fold($0.name).hasPrefix(folded) }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: Matching

    /// How a query matches a command, Space or settings page: the text
    /// starts with it, beats every word starting a word, beats every word
    /// appearing anywhere. Case and accents ignored.
    enum TextTier: Int, Comparable, Sendable {
        case substring = 1
        case wordStart = 2
        case prefix = 3

        static func < (lhs: TextTier, rhs: TextTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The best tier of `query` over `texts` (a title and its synonyms).
    static func textTier(_ query: String, in texts: [String]) -> TextTier? {
        let folded = fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return nil }
        let terms = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var best: TextTier?
        for text in texts {
            let haystack = fold(text)
            let tier: TextTier?
            if haystack.hasPrefix(folded) {
                tier = .prefix
            } else {
                let words = haystack.split { !$0.isLetter && !$0.isNumber }
                if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) {
                    tier = .wordStart
                } else if terms.allSatisfy({ haystack.contains($0) }) {
                    tier = .substring
                } else {
                    tier = nil
                }
            }
            if let tier, best.map({ tier > $0 }) ?? true {
                best = tier
            }
        }
        return best
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Actions matching `term` (every one for an empty term), best tier
    /// first, then registry order.
    private static func rankedActions(
        _ actions: [BrowserCommandBarInput.Action],
        term: String,
        minimumTier: TextTier
    ) -> [BrowserCommandBarRow] {
        // Rank: the tier, then a title match before a synonym match of the
        // same tier, then registry order.
        let matched: [(index: Int, tier: TextTier, byTitle: Bool, action: BrowserCommandBarInput.Action)]
        if term.isEmpty {
            matched = actions.enumerated().map { ($0.offset, .prefix, true, $0.element) }
        } else {
            matched = actions.enumerated().compactMap { index, action in
                let title = textTier(term, in: [action.title])
                let synonym = textTier(term, in: action.synonyms)
                guard let best = [title, synonym].compactMap({ $0 }).max(), best >= minimumTier else { return nil }
                return (index, best, title == best, action)
            }
        }
        return matched
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
                if lhs.byTitle != rhs.byTitle { return lhs.byTitle }
                return lhs.index < rhs.index
            }
            .map { _, _, _, action in
                BrowserCommandBarRow(
                    kind: .action,
                    title: action.title,
                    shortcut: action.shortcut,
                    symbol: action.symbol,
                    target: .command(action.id)
                )
            }
    }

    private static func tabRow(_ tab: BrowserCommandBarInput.Tab) -> BrowserCommandBarRow {
        let display = AddressURLText.display(tab.url)
        return BrowserCommandBarRow(
            kind: .tab,
            title: tab.title.isEmpty ? display : tab.title,
            detail: tab.otherSpace ?? display,
            symbol: "square.on.square",
            target: .tab(tab.id)
        )
    }

    private static func append(_ title: String, _ rows: [BrowserCommandBarRow], to groups: inout [BrowserCommandBarGroup]) {
        guard !rows.isEmpty else { return }
        groups.append(BrowserCommandBarGroup(title: title, rows: rows))
    }
}
