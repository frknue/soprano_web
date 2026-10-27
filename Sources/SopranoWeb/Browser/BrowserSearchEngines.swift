import Foundation

/// A search engine's id: a built-in's fixed name (`duckDuckGo`, `google`,
/// `bing`, the values settings files have always held) or a custom
/// engine's UUID string.
struct BrowserSearchEngineID: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let duckDuckGo = BrowserSearchEngineID(rawValue: "duckDuckGo")
    static let google = BrowserSearchEngineID(rawValue: "google")
    static let bing = BrowserSearchEngineID(rawValue: "bing")

    /// A fresh id for a custom engine.
    static func makeCustom() -> BrowserSearchEngineID {
        BrowserSearchEngineID(rawValue: UUID().uuidString)
    }
}

/// A search engine: one of the built-ins or one added in Settings ▸ Search
/// engine ▸ Manage… (`customSearchEngines` in `settings.json`; a built-in's
/// keyword is in `searchEngineKeywords`).
struct BrowserSearchEngine: Codable, Equatable, Sendable, Identifiable {
    var id: BrowserSearchEngineID
    var name: String
    /// "keyword query" in the address field searches this engine. Lowercase
    /// without whitespace (`normalizedKeyword`); empty means none.
    var keyword: String
    /// An http(s) URL with `%s` where the percent-encoded query goes.
    var template: String

    init(id: BrowserSearchEngineID, name: String, keyword: String, template: String) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.template = template
    }

    static let duckDuckGo = BrowserSearchEngine(
        id: .duckDuckGo,
        name: "DuckDuckGo",
        keyword: "",
        template: "https://duckduckgo.com/?q=%s"
    )
    static let google = BrowserSearchEngine(
        id: .google,
        name: "Google",
        keyword: "",
        template: "https://www.google.com/search?q=%s"
    )
    static let bing = BrowserSearchEngine(
        id: .bing,
        name: "Bing",
        keyword: "",
        template: "https://www.bing.com/search?q=%s"
    )
    /// In menu order, without keywords: a fixed one-letter keyword would take
    /// ordinary searches ("b tree"). Only their keyword can be set; they
    /// can't be removed.
    static let builtIn: [BrowserSearchEngine] = [.duckDuckGo, .google, .bing]

    var isBuiltIn: Bool {
        Self.builtIn.contains { $0.id == id }
    }

    /// The template with `%s` replaced by `query`, percent-encoded so it is
    /// safe anywhere in a URL (only RFC 3986's unreserved characters stay).
    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? ""
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// A GET form that reaches the same URL as `searchURL`, for the start
    /// page (its CSP allows `form-action https:` only, and it runs no
    /// script). Nil unless the template is https and `%s` is a whole query
    /// value, e.g. `…/search?q=%s`.
    var searchForm: BrowserSearchForm? {
        let marker = "__soprano_query__"
        guard !template.contains(marker),
              var components = URLComponents(string: template.replacingOccurrences(of: "%s", with: marker)),
              components.scheme?.lowercased() == "https",
              let items = components.queryItems,
              items.filter({ $0.value == marker }).count == 1,
              let field = items.first(where: { $0.value == marker })?.name
        else { return nil }
        let hidden = items.filter { $0.value != marker }
        guard !hidden.contains(where: { $0.name.contains(marker) || ($0.value ?? "").contains(marker) }) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let action = components.string, !action.contains(marker) else { return nil }
        return BrowserSearchForm(
            action: action,
            field: field,
            hidden: hidden.map { BrowserSearchForm.Field(name: $0.name, value: $0.value ?? "") }
        )
    }

    /// Lowercase with every whitespace character removed.
    static func normalizedKeyword(_ keyword: String) -> String {
        keyword.lowercased().filter { !$0.isWhitespace }
    }

    /// True for an http(s) URL with a host and at least one `%s`, without
    /// whitespace.
    static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              !template.contains(where: \.isWhitespace),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "query")),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// RFC 3986 unreserved characters, ASCII only.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

extension BrowserSearchEngine {
    /// One `customSearchEngines` entry. A missing id gets a fresh one; an
    /// empty name or an invalid template fails the entry (the list skips
    /// it). The keyword is normalized; a missing one means none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rawID = text(.id)
        let name = text(.name)
        let template = text(.template)
        let keyword = text(.keyword)
        guard !name.isEmpty, Self.isValidTemplate(template) else {
            throw DecodingError.dataCorruptedError(
                forKey: .template,
                in: c,
                debugDescription: "A search engine needs a name and an http(s) template with %s."
            )
        }
        self.init(
            id: rawID.isEmpty ? .makeCustom() : BrowserSearchEngineID(rawValue: rawID),
            name: name,
            keyword: Self.normalizedKeyword(keyword),
            template: template
        )
    }
}

/// `searchEngineKeywords`: a JSON object of strings; a value that is not a
/// string is skipped, the rest kept.
struct BrowserSearchKeywordMap: Decodable {
    var keywords: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        var keywords: [String: String] = [:]
        for key in c.allKeys {
            if let keyword = try? c.decode(String.self, forKey: key) {
                keywords[key.stringValue] = keyword
            }
        }
        self.keywords = keywords
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}

/// The start page's search form for an engine.
struct BrowserSearchForm: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// The template without its query.
    var action: String
    /// The text field's name.
    var field: String
    /// The template's other query items, sent as hidden fields.
    var hidden: [Field]
}

/// "keyword query" typed into the address field or the Command Bar.
struct BrowserKeywordSearch: Equatable, Sendable {
    var engine: BrowserSearchEngine
    var query: String

    var url: URL? {
        engine.searchURL(for: query)
    }
}

/// Why an engine can't be saved in Settings ▸ Search engines.
enum BrowserSearchEngineProblem: Equatable, Sendable {
    case emptyName
    case invalidTemplate
    case keywordInUse(by: String)

    var message: String {
        switch self {
        case .emptyName: "Enter a name."
        case .invalidTemplate: "Enter an http or https URL with %s where the search terms go."
        case .keywordInUse(let name): "\(name) already uses this keyword."
        }
    }
}

/// Every engine (built-ins, then the custom ones) and the default. The pure
/// API the address field, Settings and the Command Bar share: keywords,
/// "keyword query" parsing and search URLs.
struct BrowserSearchEngines: Equatable, Sendable {
    private(set) var custom: [BrowserSearchEngine]
    /// The keywords the user gave built-ins, by built-in id
    /// (`searchEngineKeywords` in `settings.json`); normalized, never empty.
    private(set) var builtInKeywords: [String: String]
    /// Always a built-in's or one of `custom`'s.
    private(set) var defaultID: BrowserSearchEngineID

    static let `default` = BrowserSearchEngines()

    /// Keeps what is valid. Built-in keywords first: an unknown id, an empty
    /// keyword or one an earlier built-in has is dropped. Then custom
    /// engines: a built-in's or a repeated id, an empty name, an invalid
    /// template or a keyword already taken drops the entry. An unknown
    /// default falls back to DuckDuckGo.
    init(
        custom: [BrowserSearchEngine] = [],
        builtInKeywords: [String: String] = [:],
        defaultID: BrowserSearchEngineID = .duckDuckGo
    ) {
        var keywords: Set<String> = []
        var keptKeywords: [String: String] = [:]
        for engine in BrowserSearchEngine.builtIn {
            guard let raw = builtInKeywords[engine.id.rawValue] else { continue }
            let keyword = BrowserSearchEngine.normalizedKeyword(raw)
            guard !keyword.isEmpty, keywords.insert(keyword).inserted else { continue }
            keptKeywords[engine.id.rawValue] = keyword
        }
        var kept: [BrowserSearchEngine] = []
        var ids = Set(BrowserSearchEngine.builtIn.map(\.id))
        for var engine in custom {
            engine.name = engine.name.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.template = engine.template.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.keyword = BrowserSearchEngine.normalizedKeyword(engine.keyword)
            guard !engine.name.isEmpty,
                  BrowserSearchEngine.isValidTemplate(engine.template),
                  ids.insert(engine.id).inserted
            else { continue }
            if !engine.keyword.isEmpty {
                guard keywords.insert(engine.keyword).inserted else { continue }
            }
            kept.append(engine)
        }
        self.custom = kept
        self.builtInKeywords = keptKeywords
        self.defaultID = ids.contains(defaultID) ? defaultID : .duckDuckGo
    }

    /// The built-ins with their keywords, then the custom engines.
    var all: [BrowserSearchEngine] {
        BrowserSearchEngine.builtIn.map { engine in
            var engine = engine
            engine.keyword = builtInKeywords[engine.id.rawValue] ?? ""
            return engine
        } + custom
    }

    var defaultEngine: BrowserSearchEngine {
        engine(id: defaultID) ?? .duckDuckGo
    }

    func engine(id: BrowserSearchEngineID) -> BrowserSearchEngine? {
        all.first { $0.id == id }
    }

    /// The engine whose keyword is `keyword`, case and whitespace ignored.
    func engine(forKeyword keyword: String) -> BrowserSearchEngine? {
        let normalized = BrowserSearchEngine.normalizedKeyword(keyword)
        guard !normalized.isEmpty else { return nil }
        return all.first { $0.keyword == normalized }
    }

    /// "keyword query": the first word is an engine's keyword and a query
    /// follows it. A bare keyword, or anything whose first word is not a
    /// keyword (an address included), is nil.
    func resolve(_ input: String) -> BrowserKeywordSearch? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let query = trimmed[gap...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let engine = engine(forKeyword: String(trimmed[..<gap])) else { return nil }
        return BrowserKeywordSearch(engine: engine, query: query)
    }

    func searchURL(engine: BrowserSearchEngine, query: String) -> URL? {
        engine.searchURL(for: query)
    }

    // MARK: Editing

    /// Why `name`, `keyword` and `template` can't be saved (as the engine
    /// `id` when editing one), or nil.
    func problem(
        name: String,
        keyword: String,
        template: String,
        editing id: BrowserSearchEngineID? = nil
    ) -> BrowserSearchEngineProblem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if !BrowserSearchEngine.isValidTemplate(template.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .invalidTemplate
        }
        if let owner = engine(forKeyword: keyword), owner.id != id {
            return .keywordInUse(by: owner.name)
        }
        return nil
    }

    /// Adds a custom engine or replaces the one with its id; for a built-in
    /// only the keyword is taken (empty clears it). Returns false (and
    /// changes nothing) when it can't be saved.
    @discardableResult
    mutating func save(_ engine: BrowserSearchEngine) -> Bool {
        if let builtIn = BrowserSearchEngine.builtIn.first(where: { $0.id == engine.id }) {
            guard problem(
                name: builtIn.name,
                keyword: engine.keyword,
                template: builtIn.template,
                editing: builtIn.id
            ) == nil else { return false }
            var keywords = builtInKeywords
            keywords[builtIn.id.rawValue] = engine.keyword
            self = BrowserSearchEngines(custom: custom, builtInKeywords: keywords, defaultID: defaultID)
            return true
        }
        guard problem(name: engine.name, keyword: engine.keyword, template: engine.template, editing: engine.id) == nil
        else { return false }
        var list = custom
        if let index = list.firstIndex(where: { $0.id == engine.id }) {
            list[index] = engine
        } else {
            list.append(engine)
        }
        self = BrowserSearchEngines(custom: list, builtInKeywords: builtInKeywords, defaultID: defaultID)
        return true
    }

    /// Removes a custom engine; the default falls back to DuckDuckGo when
    /// it was this one. Built-ins stay.
    mutating func remove(id: BrowserSearchEngineID) {
        self = BrowserSearchEngines(
            custom: custom.filter { $0.id != id },
            builtInKeywords: builtInKeywords,
            defaultID: defaultID
        )
    }

    /// Makes an existing engine the default.
    mutating func setDefault(_ id: BrowserSearchEngineID) {
        guard engine(id: id) != nil else { return }
        defaultID = id
    }
}
