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
        /// `Search “query”` with the configured engine.
        case search
        /// A phrase from the search engine's suggestion service.
        case searchSuggestion
    }

    enum Target: Equatable, Sendable {
        case url(String)
        case search(String)
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
    var history: [BrowserHistoryEntry] = []
    var bookmarks: [BrowserBookmark] = []
    /// Open tabs other than the selected one.
    var tabs: [AddressSuggestionTab] = []
    var searchEngine: SearchEngine = .duckDuckGo
    var remoteSuggestions: [String] = []
    /// False after a deletion, so backspace never re-completes.
    var allowsInlineCompletion = true
    var now = Date()
    var limit = 8
}

// MARK: - Visits

/// History aggregated per URL: how often it was visited, how often the visit
/// started from the address bar, and when it was last seen.
struct AddressVisitStats: Equatable, Sendable {
    var url: String
    var title: String
    var visits: Int
    var typedVisits: Int
    var lastVisit: Date
}

// MARK: - Engine

enum AddressSuggestionEngine {
    static let maxTabRows = 3
    static let reservedSuggestionRows = 3

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
                visits: 0,
                typedVisits: 0,
                lastVisit: nil,
                isBookmarked: false
            ))
        }

        var pages: [String: Candidate] = [:]
        for stats in visitStats(input.history) {
            let key = AddressURLText.key(stats.url)
            guard !key.isEmpty else { continue }
            if var existing = pages[key] {
                existing.visits += stats.visits
                existing.typedVisits += stats.typedVisits
                if let last = existing.lastVisit, last >= stats.lastVisit {
                    if existing.title.isEmpty { existing.title = stats.title }
                } else {
                    existing.lastVisit = stats.lastVisit
                    existing.url = stats.url
                    if !stats.title.isEmpty { existing.title = stats.title }
                }
                pages[key] = existing
            } else {
                pages[key] = Candidate(
                    key: key,
                    url: stats.url,
                    title: stats.title,
                    kind: .history,
                    tabID: nil,
                    visits: stats.visits,
                    typedVisits: stats.typedVisits,
                    lastVisit: stats.lastVisit,
                    isBookmarked: false
                )
            }
        }
        for bookmark in input.bookmarks {
            let key = AddressURLText.key(bookmark.url)
            guard !key.isEmpty else { continue }
            if var existing = pages[key] {
                existing.isBookmarked = true
                existing.kind = .bookmark
                let title = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { existing.title = title }
                pages[key] = existing
            } else {
                pages[key] = Candidate(
                    key: key,
                    url: bookmark.url,
                    title: bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: .bookmark,
                    tabID: nil,
                    visits: 0,
                    typedVisits: 0,
                    lastVisit: bookmark.addedAt,
                    isBookmarked: true
                )
            }
        }
        let pageCandidates = pages.values.filter { !tabKeys.contains($0.key) }

        let rankedTabs = rank(tabCandidates, matcher: matcher, now: input.now)
        var rankedPages = rank(pageCandidates, matcher: matcher, now: input.now)

        // The first row is what Return opens without touching the arrows.
        let searchRow = AddressSuggestion(
            kind: .search,
            title: "Search “\(query)”",
            detail: input.searchEngine.name,
            target: .search(query),
            fillText: query
        )
        var tabRows = rankedTabs.prefix(maxTabRows).map(\.candidate)
        var defaultRow: AddressSuggestion
        var completionText: String?
        let looksLikeAddress = AddressQueryMatcher.looksLikeAddress(query, engine: input.searchEngine)

        if input.allowsInlineCompletion,
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
                  let resolved = BrowserAddressResolver.resolve(query, searchEngine: input.searchEngine)
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

    /// Visit counts per exact URL, newest first; typed counts from entries the
    /// address bar started. Older entries without the flag count as not typed.
    static func visitStats(_ history: [BrowserHistoryEntry]) -> [AddressVisitStats] {
        var byURL: [String: AddressVisitStats] = [:]
        var order: [String] = []
        for entry in history {
            let typed = entry.typed == true ? 1 : 0
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if var stats = byURL[entry.url] {
                stats.visits += 1
                stats.typedVisits += typed
                if entry.visitedAt > stats.lastVisit {
                    stats.lastVisit = entry.visitedAt
                    if !title.isEmpty { stats.title = title }
                } else if stats.title.isEmpty {
                    stats.title = title
                }
                byURL[entry.url] = stats
            } else {
                order.append(entry.url)
                byURL[entry.url] = AddressVisitStats(
                    url: entry.url,
                    title: title,
                    visits: 1,
                    typedVisits: typed,
                    lastVisit: entry.visitedAt
                )
            }
        }
        return order.compactMap { byURL[$0] }.sorted { $0.lastVisit > $1.lastVisit }
    }

    /// Frequency and recency boost within a match tier: typed visits weigh
    /// three visits, a bookmark two, and the total halves after a week.
    static func boost(visits: Int, typedVisits: Int, isBookmarked: Bool, lastVisit: Date?, now: Date) -> Double {
        let frequency = Double(visits) + Double(typedVisits) * 2 + (isBookmarked ? 2 : 0)
        let ageDays = lastVisit.map { max(0, now.timeIntervalSince($0)) / 86_400 } ?? 365
        let recency = 1 / (1 + ageDays / 7)
        return log2(1 + frequency) * (0.5 + recency) + recency
    }

    // MARK: Private

    fileprivate struct Candidate {
        var key: String
        var url: String
        var title: String
        var kind: AddressSuggestion.Kind
        var tabID: UUID?
        var visits: Int
        var typedVisits: Int
        var lastVisit: Date?
        var isBookmarked: Bool
    }

    fileprivate struct Ranked {
        var candidate: Candidate
        var tier: AddressQueryMatcher.Tier
        var score: Double
    }

    private static func rank(_ candidates: [Candidate], matcher: AddressQueryMatcher, now: Date) -> [Ranked] {
        candidates.compactMap { candidate -> Ranked? in
            guard let tier = matcher.tier(url: candidate.url, title: candidate.title) else { return nil }
            let score = boost(
                visits: candidate.visits,
                typedVisits: candidate.typedVisits,
                isBookmarked: candidate.isBookmarked,
                lastVisit: candidate.lastVisit,
                now: now
            )
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
    /// than search for it.
    static func looksLikeAddress(_ query: String, engine: SearchEngine) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = BrowserAddressResolver.resolve(trimmed, searchEngine: engine) else { return false }
        return resolved != engine.searchURL(for: trimmed)
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

extension SearchEngine {
    /// The engine's OpenSearch-style suggestion endpoint for `query`.
    func suggestionURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
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
