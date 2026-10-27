import Foundation

// MARK: - Rows

/// One row of the address bar dropdown.
struct AddressSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// An open tab; choosing it selects that tab.
        case switchToTab
        case history
        case bookmark
        /// The typed or inline-completed address itself.
        case url
        /// `Search “query”` with the configured engine, or `Search Engine
        /// for “query”` for a "keyword query".
        case search
        /// A phrase from the search engine's suggestion service.
        case searchSuggestion
    }

    enum Target: Equatable, Sendable {
        case url(String)
        /// The default engine's search.
        case search(String)
        /// "keyword query": that engine's search.
        case keywordSearch(engine: BrowserSearchEngineID, query: String)
        case tab(UUID)
    }

    var kind: Kind
    var title: String
    /// The URL shown in SF Mono, scheme and `www.` removed; empty for searches.
    var detail: String
    var target: Target
    /// What the field shows while this row is selected with ↑/↓.
    var fillText: String
}

struct AddressSuggestionResult: Equatable, Sendable {
    var rows: [AddressSuggestion]
    /// The full field text after inline completion: the query as typed plus
    /// the completed rest of the host. Nil when nothing completes.
    var inlineCompletion: String?

    static let empty = AddressSuggestionResult(rows: [], inlineCompletion: nil)
}

/// An open tab as the engine sees it.
struct AddressSuggestionTab: Equatable, Sendable {
    var id: UUID
    var title: String
    var url: String
}

struct AddressSuggestionInput: Sendable {
    var query: String
    /// History's candidates for the query (`BrowserHistoryStore.suggestionCandidates`).
    var history: [BrowserHistoryPage] = []
    /// The window's current Space's pins.
    var pins: [BrowserPin] = []
    /// Open tabs other than the selected one.
    var tabs: [AddressSuggestionTab] = []
    var searchEngines: BrowserSearchEngines = .default
    var remoteSuggestions: [String] = []
    /// False after a deletion, so backspace never re-completes.
    var allowsInlineCompletion = true
    var limit = 8
}

extension AddressSuggestionInput {
    /// A window's suggestion sources: its Space's pins, its own open tabs
    /// and the search engine, plus History unless the window keeps History
    /// out (a private window).
    init(
        query: String,
        kind: BrowserWindowKind,
        history: [BrowserHistoryPage],
        pins: [BrowserPin],
        tabs: [AddressSuggestionTab],
        searchEngines: BrowserSearchEngines
    ) {
        self.init(
            query: query,
            history: kind.suggestsHistory ? history : [],
            pins: pins,
            tabs: tabs,
            searchEngines: searchEngines
        )
    }
}

// MARK: - Engine

enum AddressSuggestionEngine {
    static let maxTabRows = 3
    static let reservedSuggestionRows = 3

    /// A History page or pin matching a query, ranked as the address bar
    /// ranks them (the Command Bar's pins and history).
    struct PageMatch: Equatable, Sendable {
        var url: String
        var title: String
        /// The page is one of the pins passed in (its History merged in).
        var isPinned: Bool
        var tier: AddressQueryMatcher.Tier
        var score: Double
    }

    /// History and pins matching `query`, best first: the match tier (host
    /// prefix > title word start > substring), then frecency plus the pin
    /// bonus. One row per page (URL key).
    static func rankedPages(query: String, history: [BrowserHistoryPage], pins: [BrowserPin]) -> [PageMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let candidates = Array(pageCandidates(history: history, pins: pins).values)
        return rank(candidates, matcher: AddressQueryMatcher(query: trimmed)).map { ranked in
            PageMatch(
                url: ranked.candidate.url,
                title: ranked.candidate.title,
                isPinned: ranked.candidate.isBookmarked,
                tier: ranked.tier,
                score: ranked.score
            )
        }
    }

    /// History pages and pins by URL key; a pin absorbs the History of the
    /// same page.
    fileprivate static func pageCandidates(history: [BrowserHistoryPage], pins: [BrowserPin]) -> [String: Candidate] {
        var pages: [String: Candidate] = [:]
        for page in history {
            let key = AddressURLText.key(page.url)
            guard !key.isEmpty else { continue }
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if var existing = pages[key] {
                existing.frecency += page.frecency
                if let last = existing.lastVisit, last >= page.lastVisit {
                    if existing.title.isEmpty { existing.title = title }
                } else {
                    existing.lastVisit = page.lastVisit
                    existing.url = page.url
                    if !title.isEmpty { existing.title = title }
                }
                pages[key] = existing
            } else {
                pages[key] = Candidate(
                    key: key,
                    url: page.url,
                    title: title,
                    kind: .history,
                    tabID: nil,
                    frecency: page.frecency,
                    lastVisit: page.lastVisit,
                    isBookmarked: false
                )
            }
        }
        for pin in pins {
            let key = AddressURLText.key(pin.url)
            guard !key.isEmpty else { continue }
            if var existing = pages[key] {
                existing.isBookmarked = true
                existing.kind = .bookmark
                let title = pin.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { existing.title = title }
                pages[key] = existing
            } else {
                pages[key] = Candidate(
                    key: key,
                    url: pin.url,
                    title: pin.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: .bookmark,
                    tabID: nil,
                    frecency: 0,
                    lastVisit: pin.addedAt,
                    isBookmarked: true
                )
            }
        }
        return pages
    }

    static func suggestions(for input: AddressSuggestionInput) -> AddressSuggestionResult {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .empty }
        let matcher = AddressQueryMatcher(query: query)

        // Local candidates, deduplicated by URL key; open tabs win, then
        // bookmarks absorb the history of the same page.
        var tabCandidates: [Candidate] = []
        var tabKeys: Set<String> = []
        for tab in input.tabs {
            let key = AddressURLText.key(tab.url)
            guard !key.isEmpty, !tabKeys.contains(key) else { continue }
            tabKeys.insert(key)
            tabCandidates.append(Candidate(
                key: key,
                url: tab.url,
                title: tab.title,
                kind: .switchToTab,
                tabID: tab.id,
                frecency: 0,
                lastVisit: nil,
                isBookmarked: false
            ))
        }

        let pages = Self.pageCandidates(history: input.history, pins: input.pins).values
            .filter { !tabKeys.contains($0.key) }

        let rankedTabs = rank(tabCandidates, matcher: matcher)
        var rankedPages = rank(Array(pages), matcher: matcher)

        // The first row is what Return opens without touching the arrows.
        let searchRow = AddressSuggestion(
            kind: .search,
            title: "Search “\(query)”",
            detail: input.searchEngines.defaultEngine.name,
            target: .search(query),
            fillText: query
        )
        var tabRows = rankedTabs.prefix(maxTabRows).map(\.candidate)
        var defaultRow: AddressSuggestion
        var completionText: String?
        let keywordSearch = input.searchEngines.resolve(query)
        let looksLikeAddress = keywordSearch == nil && AddressQueryMatcher.looksLikeAddress(query)

        if let keywordSearch {
            // "d cats": the keyword's engine. The default engine's search
            // for the whole text stays below as the search row.
            defaultRow = AddressSuggestion(
                kind: .search,
                title: "Search \(keywordSearch.engine.name) for “\(keywordSearch.query)”",
                detail: "",
                target: .keywordSearch(engine: keywordSearch.engine.id, query: keywordSearch.query),
                fillText: query
            )
        } else if input.allowsInlineCompletion,
                  let completion = hostCompletion(matcher: matcher, ranked: rankedTabs + rankedPages)
        {
            completionText = completion.fieldText
            let rootKey = AddressURLText.key(completion.url)
            if let index = tabRows.firstIndex(where: { $0.key == rootKey }) {
                defaultRow = row(for: tabRows.remove(at: index))
            } else if let index = rankedPages.firstIndex(where: { $0.candidate.key == rootKey }) {
                var page = row(for: rankedPages.remove(at: index).candidate)
                page.target = .url(completion.url)
                defaultRow = page
            } else {
                defaultRow = AddressSuggestion(
                    kind: .url,
                    title: completion.authority,
                    detail: AddressURLText.display(completion.url),
                    target: .url(completion.url),
                    fillText: completion.fieldText
                )
            }
            defaultRow.fillText = completion.fieldText
        } else if looksLikeAddress,
                  let resolved = BrowserAddressResolver.address(for: query)
        {
            let address = resolved.absoluteString
            let key = AddressURLText.key(address)
            var title = query
            if let index = rankedPages.firstIndex(where: { $0.candidate.key == key }) {
                let page = rankedPages.remove(at: index).candidate
                if !page.title.isEmpty { title = page.title }
            }
            defaultRow = AddressSuggestion(
                kind: .url,
                title: title,
                detail: AddressURLText.display(address),
                target: .url(address),
                fillText: query
            )
        } else {
            defaultRow = searchRow
        }

        let showsSearchRow = !looksLikeAddress && defaultRow.target != searchRow.target
        let remote = remoteRows(input.remoteSuggestions, query: query)
        let fixed = 1 + (showsSearchRow ? 1 : 0)
        let localCap = max(0, input.limit - fixed - min(remote.count, reservedSuggestionRows))
        let local = (tabRows + rankedPages.map(\.candidate)).prefix(localCap).map(row(for:))
        let suggestionCap = max(0, input.limit - fixed - local.count)

        var rows = [defaultRow] + local
        if showsSearchRow { rows.append(searchRow) }
        rows += remote.prefix(suggestionCap)
        return AddressSuggestionResult(rows: Array(rows.prefix(input.limit)), inlineCompletion: completionText)
    }

    /// What a bookmark adds to a page's frecency (Firefox's points for an
    /// unvisited bookmark).
    static let bookmarkBonus: Double = 140

    /// The order within a match tier: History's frecency
    /// (`BrowserFrecency`, typed visits weighing three) plus the bookmark
    /// bonus. Open tabs have none and sort by address length.
    static func rankScore(frecency: Double, isBookmarked: Bool) -> Double {
        frecency + (isBookmarked ? bookmarkBonus : 0)
    }

    // MARK: Private

    fileprivate struct Candidate {
        var key: String
        var url: String
        var title: String
        var kind: AddressSuggestion.Kind
        var tabID: UUID?
        var frecency: Double
        var lastVisit: Date?
        var isBookmarked: Bool
    }

    fileprivate struct Ranked {
        var candidate: Candidate
        var tier: AddressQueryMatcher.Tier
        var score: Double
    }

    private static func rank(_ candidates: [Candidate], matcher: AddressQueryMatcher) -> [Ranked] {
        candidates.compactMap { candidate -> Ranked? in
            guard let tier = matcher.tier(url: candidate.url, title: candidate.title) else { return nil }
            let score = rankScore(frecency: candidate.frecency, isBookmarked: candidate.isBookmarked)
            return Ranked(candidate: candidate, tier: tier, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = AddressURLText.display(lhs.candidate.url).count
            let rhsLength = AddressURLText.display(rhs.candidate.url).count
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.candidate.url < rhs.candidate.url
        }
    }

    private struct Completion {
        var authority: String
        var url: String
        var fieldText: String
    }

    /// Completes the host of the strongest site whose host starts with the
    /// query. Sites rank by the summed boost of their matching pages.
    private static func hostCompletion(matcher: AddressQueryMatcher, ranked: [Ranked]) -> Completion? {
        guard let hostQuery = matcher.hostQuery, !hostQuery.isEmpty, !hostQuery.contains("/") else { return nil }
        struct Site {
            var authority: String
            var url: String
            var score: Double
            var newest: Date
        }
        var sites: [String: Site] = [:]
        for item in ranked where item.tier == .hostPrefix {
            guard let parts = AddressURLText.authority(of: item.candidate.url) else { continue }
            let bare = parts.bare.lowercased()
            guard bare.hasPrefix(hostQuery), bare.count > hostQuery.count else { continue }
            let root = "\(parts.scheme)://\(parts.authority)/"
            let seen = item.candidate.lastVisit ?? .distantPast
            if var site = sites[bare] {
                site.score += item.score
                if seen > site.newest {
                    site.newest = seen
                    site.url = root
                }
                sites[bare] = site
            } else {
                sites[bare] = Site(authority: parts.bare, url: root, score: item.score, newest: seen)
            }
        }
        guard let best = sites.values.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.authority.count != rhs.authority.count { return lhs.authority.count > rhs.authority.count }
            return lhs.authority > rhs.authority
        }) else { return nil }
        let rest = String(best.authority.dropFirst(hostQuery.count))
        return Completion(authority: best.authority, url: best.url, fieldText: matcher.query + rest)
    }

    private static func row(for candidate: Candidate) -> AddressSuggestion {
        let display = AddressURLText.display(candidate.url)
        let title = candidate.title.isEmpty ? display : candidate.title
        if candidate.kind == .switchToTab, let id = candidate.tabID {
            return AddressSuggestion(kind: .switchToTab, title: title, detail: display, target: .tab(id), fillText: candidate.url)
        }
        return AddressSuggestion(
            kind: candidate.kind,
            title: title,
            detail: display,
            target: .url(candidate.url),
            fillText: candidate.url
        )
    }

    private static func remoteRows(_ phrases: [String], query: String) -> [AddressSuggestion] {
        var seen: Set<String> = [query.lowercased()]
        var rows: [AddressSuggestion] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            rows.append(AddressSuggestion(
                kind: .searchSuggestion,
                title: trimmed,
                detail: "",
                target: .search(trimmed),
                fillText: trimmed
            ))
        }
        return rows
    }
}

// MARK: - Matching

struct AddressQueryMatcher {
    enum Tier: Int, Comparable {
        case substring = 1
        case titleWordStart = 2
        case hostPrefix = 3

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The query as typed, trimmed.
    let query: String
    /// The lowercased query without scheme and `www.`, when it has no spaces.
    let hostQuery: String?
    let terms: [String]

    init(query: String) {
        self.query = query
        let lowered = query.lowercased()
        terms = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        if lowered.contains(where: \.isWhitespace) {
            hostQuery = nil
        } else {
            var stripped = Substring(lowered)
            for scheme in ["https://", "http://"] where stripped.hasPrefix(scheme) {
                stripped = stripped.dropFirst(scheme.count)
            }
            if stripped.hasPrefix("www.") {
                stripped = stripped.dropFirst(4)
            }
            hostQuery = stripped.isEmpty ? nil : String(stripped)
        }
    }

    /// Host prefix (scheme and `www.` ignored) beats a word start in the
    /// title, which beats a substring anywhere. Nil means no match.
    func tier(url: String, title: String) -> Tier? {
        let display = AddressURLText.display(url).lowercased()
        if let hostQuery, display.hasPrefix(hostQuery) {
            return .hostPrefix
        }
        guard !terms.isEmpty else { return nil }
        let words = Self.words(title.lowercased())
        if terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) {
            return .titleWordStart
        }
        let haystack = title.lowercased() + " " + display
        if query.count >= 2, terms.allSatisfy({ haystack.contains($0) }) {
            return .substring
        }
        return nil
    }

    /// True when the address bar would open the query as an address rather
    /// than search for it ("keyword query" is a search, so callers check
    /// keywords first).
    static func looksLikeAddress(_ query: String) -> Bool {
        BrowserAddressResolver.address(for: query) != nil
    }

    private static func words(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }
}

// MARK: - URL text

enum AddressURLText {
    /// The URL as the dropdown shows it: no `http(s)://`, no `www.`, and no
    /// trailing slash on a bare host.
    static func display(_ url: String) -> String {
        var text = Substring(url)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = text.dropFirst(scheme.count)
        }
        if text.lowercased().hasPrefix("www.") {
            text = text.dropFirst(4)
        }
        if text.hasSuffix("/"), text.dropLast().firstIndex(of: "/") == nil {
            text = text.dropLast()
        }
        return String(text)
    }

    /// The identity used to merge one page across history, bookmarks and
    /// tabs: scheme, `www.`, fragment and a trailing slash do not count.
    static func key(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.host != nil || components.scheme == "file" else {
            return url.lowercased()
        }
        components.fragment = nil
        var host = components.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let port = components.port.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let scheme = components.scheme?.lowercased() ?? ""
        let prefix = ["http", "https"].contains(scheme) ? "" : "\(scheme)://"
        return prefix + host + port + path + query
    }

    /// Scheme, `host[:port]` as written, and the same without `www.`.
    static func authority(of url: String) -> (scheme: String, authority: String, bare: String)? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let authority = host + port
        let bare = authority.lowercased().hasPrefix("www.") ? String(authority.dropFirst(4)) : authority
        return (scheme, authority, bare)
    }
}

// MARK: - Inline completion

enum AddressInlineCompletion {
    /// Completion follows typing forward only: never after a deletion, with
    /// the caret inside the text, or while an input method composes.
    static func isAllowed(lastEditWasDeletion: Bool, caretAtEnd: Bool, hasMarkedText: Bool) -> Bool {
        !lastEditWasDeletion && caretAtEnd && !hasMarkedText
    }

    /// The part to append after `typed` and select, or nil when `completion`
    /// does not extend what was typed.
    static func suffix(typed: String, completion: String?) -> String? {
        guard let completion,
              completion.count > typed.count,
              completion.lowercased().hasPrefix(typed.lowercased())
        else { return nil }
        return String(completion.dropFirst(typed.count))
    }
}

// MARK: - Search engine suggestions

extension BrowserSearchEngine {
    /// A built-in engine's OpenSearch-style suggestion endpoint for
    /// `query`; custom engines have none.
    func suggestionURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch id {
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/ac/"
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "list"),
            ]
        case .google:
            components.host = "suggestqueries.google.com"
            components.path = "/complete/search"
            components.queryItems = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "q", value: query),
            ]
        case .bing:
            components.host = "api.bing.com"
            components.path = "/osjson.aspx"
            components.queryItems = [URLQueryItem(name: "query", value: query)]
        default:
            return nil
        }
        // `+` survives URLComponents unescaped and would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

enum SearchSuggestionParser {
    /// Parses an OpenSearch suggestion response, `["query", ["a", "b"], …]`.
    /// DuckDuckGo's `[{"phrase": "a"}, …]` form is accepted too. Anything
    /// else yields no suggestions.
    static func parse(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        if let array = object as? [Any] {
            if array.count >= 2, array.first is String, let phrases = array[1] as? [Any] {
                return phrases.compactMap { $0 as? String }
            }
            return array.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
        }
        return []
    }
}
