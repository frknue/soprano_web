import Foundation

/// Why a filter did not become a content rule: WebKit has no way to
/// express it, or the line is not a usable filter.
enum BrowserFilterSkipReason: String, CaseIterable, Codable, Sendable, Error {
    case csp
    case redirect
    case removeparam
    case rewrite
    case header
    case permissions
    case badfilter
    case genericblock
    /// `##+js(…)`: uBlock Origin scriptlets.
    case scriptlet
    /// `#$#`: Adblock Plus snippets.
    case snippet
    /// `#?#`: extended CSS.
    case extendedCSS
    /// `:-abp-has(…)`, `:has-text(…)` and other procedural operators in `##`.
    case procedural
    /// `##^…` and `$$`: HTML filtering.
    case htmlFilter
    /// `#%#`: AdGuard scripts.
    case adguardScript
    /// `/regex/` filters outside WebKit's subset (`|`, `{n}`, `\d`, …).
    case regexUnsupported
    case nonASCII
    /// `example.*` domains.
    case entityDomain
    /// Only types WebKit doesn't load (`$object`, `$webrtc`).
    case unsupportedType
    case unsupportedOption
    case unsupportedSelector
    /// Exceptions with negated domains (`~a.com#@#…`).
    case unsupportedDomainList
    /// `domain=a.com|~b.a.com`: WebKit takes one domain condition per rule.
    case domainExceptionInsideInclude
    case malformed
    /// The exceptions alone fill a list.
    case tooManyExceptions
    /// WebKit rejected the rule when compiling (found by bisection).
    case compileError
}

/// The result of converting one filter list.
struct BrowserFilterConversion: Sendable {
    /// Each at most `maxRulesPerList` rules; the network lists first.
    var lists: [[BrowserContentRule]]
    var skipped: [BrowserFilterSkipReason: Int]
    /// Filter lines read (comments and headers excluded).
    var filterCount: Int

    var ruleCount: Int {
        lists.reduce(0) { $0 + $1.count }
    }
}

/// Converts Adblock Plus / EasyList filters to WebKit content rules.
///
/// - Network filters become `block` rules. `||` anchors a domain and its
///   subdomains, `|` the start or end, `^` a separator (or the end of the
///   address), `*` anything; `/…/` is a regular expression kept only when
///   WebKit accepts it. Options: `$third-party`/`$~third-party`
///   (`load-type`), `$domain=a|~b` (`if-domain`/`unless-domain`), resource
///   types and their negations (`resource-type`), `$match-case`,
///   `$important` (placed after the exceptions).
/// - `@@` exceptions become `ignore-previous-rules` with the same trigger,
///   in every network list (an exception only reaches rules of its own
///   list). `$document` excepts whole pages (`if-top-url`) in every list;
///   `$elemhide` only the element-hiding list; `$generichide` only its
///   generic rules.
/// - `##selector` rules without domains are batched into
///   `css-display-none` rules; `domain##selector` gets `if-domain`
///   (grouped by domain); `#@#` exceptions remove a selector everywhere
///   or turn into `unless-domain`.
/// - Each network list ends by letting top-level pages through (Adblock
///   Plus blocks pages only with `$document`), so a filter like `/ads/*`
///   never blocks a page the user opens.
///
/// Everything WebKit can't express is skipped and counted by reason.
enum BrowserFilterConverter {
    /// Bumped when the output changes, so cached lists are rebuilt.
    static let version = 1
    /// WebKit compiles at most this many rules into one list.
    static let maxRulesPerList = 150_000
    static let selectorsPerRule = 250

    /// `||`: the scheme, then the domain or any subdomain of it.
    static let domainAnchor = "^[^:/?#]+://([^/?#]*\\.)?"
    /// `^`: anything but a letter, a digit or `_ - . %`.
    static let separator = "[^-a-zA-Z0-9_.%]"

    static func convert(
        _ text: String,
        maxRulesPerList: Int = maxRulesPerList,
        selectorsPerRule: Int = selectorsPerRule
    ) -> BrowserFilterConversion {
        var converter = Converter()
        for line in text.split(whereSeparator: \.isNewline) {
            converter.add(line)
        }
        return converter.finish(maxRulesPerList: maxRulesPerList, selectorsPerRule: max(1, selectorsPerRule))
    }

    // MARK: - Network filters

    /// The `url-filter` for an Adblock Plus pattern, or why there is none.
    static func urlFilter(for pattern: Substring) -> Result<String, BrowserFilterSkipReason> {
        if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let regex = String(pattern.dropFirst().dropLast())
            if !regex.unicodeScalars.allSatisfy(\.isASCII) {
                return .failure(.nonASCII)
            }
            return BrowserContentRuleRegex.isSupported(regex) ? .success(regex) : .failure(.regexUnsupported)
        }
        guard pattern.unicodeScalars.allSatisfy(\.isASCII) else { return .failure(.nonASCII) }

        var body = Substring(pattern)
        var prefix = ""
        var suffix = ""
        if body.hasPrefix("||") {
            prefix = domainAnchor
            body = body.dropFirst(2)
        } else if body.hasPrefix("|") {
            prefix = "^"
            body = body.dropFirst()
        }
        if body.hasSuffix("|") {
            suffix = "$"
            body = body.dropLast()
        }
        // Unanchored ends match anywhere already.
        if prefix.isEmpty {
            while body.hasPrefix("*") { body = body.dropFirst() }
        }
        if suffix.isEmpty {
            while body.hasSuffix("*") { body = body.dropLast() }
        }

        var regex = prefix
        var previousWasWildcard = false
        for (offset, char) in zip(body.indices, body) {
            switch char {
            case "*":
                if !previousWasWildcard {
                    regex += ".*"
                }
                previousWasWildcard = true
                continue
            case "^":
                let isLast = body.index(after: offset) == body.endIndex
                let afterBareDomain = prefix == domainAnchor && !body.contains("/")
                if isLast, !afterBareDomain {
                    // A separator or the end of the address.
                    regex += suffix.isEmpty ? "(\(separator).*)?$" : "(\(separator))?"
                } else {
                    // After a bare domain the address always goes on
                    // (`/`, `:` or `?`).
                    regex += separator
                }
            case "\\", ".", "+", "?", "$", "(", ")", "[", "]", "{", "}", "|":
                regex += "\\\(char)"
            default:
                regex.append(char)
            }
            previousWasWildcard = false
        }
        regex += suffix
        if ["", "^", "$", "^$"].contains(regex) {
            regex = ".*"
        }
        return validated(regex)
    }

    private static func validated(_ regex: String) -> Result<String, BrowserFilterSkipReason> {
        BrowserContentRuleRegex.isSupported(regex) ? .success(regex) : .failure(.regexUnsupported)
    }

    /// Splits `pattern$options`. A `$` that isn't followed by options (or a
    /// regular expression's own `$`) stays in the pattern.
    static func splitOptions(_ text: Substring) -> (pattern: Substring, options: Substring?) {
        if text.count >= 2, text.hasPrefix("/"), text.hasSuffix("/") {
            return (text, nil)
        }
        guard let dollar = text.lastIndex(of: "$") else { return (text, nil) }
        let options = text[text.index(after: dollar)...]
        let looksLikeOptions = !options.isEmpty && options.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { token in
            var name = token.prefix { $0 != "=" }
            if name.hasPrefix("~") { name = name.dropFirst() }
            return !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        return looksLikeOptions ? (text[..<dollar], options) : (text, nil)
    }

    /// Network filter options as WebKit can express them.
    struct NetworkOptions {
        var types: Set<String> = []
        var negatedTypes: Set<String> = []
        var unsupportedTypes = false
        var thirdParty: Bool?
        var domains: Substring?
        var matchCase = false
        var important = false
        var document = false
        var elemhide = false
        var generichide = false

        static let typeNames: [String: String] = [
            "script": "script",
            "image": "image",
            "stylesheet": "style-sheet",
            "css": "style-sheet",
            "font": "font",
            "media": "media",
            "xmlhttprequest": "fetch",
            "xhr": "fetch",
            "subdocument": "document",
            "frame": "document",
            "websocket": "websocket",
            "ping": "ping",
            "beacon": "ping",
            "popup": "popup",
            "other": "other",
        ]

        /// Applies one option; returns why the filter can't be converted.
        mutating func apply(_ token: Substring) -> BrowserFilterSkipReason? {
            var name = Substring(token.prefix { $0 != "=" })
            let value = token.firstIndex(of: "=").map { token[token.index(after: $0)...] }
            let negated = name.hasPrefix("~")
            if negated { name = name.dropFirst() }
            let key = name.lowercased()
            if let type = Self.typeNames[key] {
                if negated {
                    negatedTypes.insert(type)
                } else {
                    types.insert(type)
                }
                return nil
            }
            switch key {
            case "third-party", "3p": thirdParty = !negated
            case "first-party", "1p": thirdParty = negated
            case "domain", "from":
                guard let value, !value.isEmpty else { return .malformed }
                domains = value
            case "match-case": matchCase = !negated
            case "important": important = true
            case "document", "doc": if !negated { document = true }
            case "elemhide", "ehide": elemhide = true
            case "generichide", "ghide": generichide = true
            case "genericblock": return .genericblock
            case "object", "object-subrequest", "webrtc":
                if !negated { unsupportedTypes = true }
            case "csp": return .csp
            case "redirect", "redirect-rule", "empty", "mp4": return .redirect
            case "removeparam", "queryprune": return .removeparam
            case "rewrite", "replace", "urltransform", "uritransform": return .rewrite
            case "header": return .header
            case "permissions": return .permissions
            case "badfilter": return .badfilter
            default: return .unsupportedOption
            }
            return nil
        }

        /// The `resource-type` list: nil when no type option restricts
        /// the filter.
        func resourceTypes() -> Result<[String]?, BrowserFilterSkipReason> {
            if !types.isEmpty {
                return .success(types.sorted())
            }
            if unsupportedTypes {
                return .failure(.unsupportedType)
            }
            if !negatedTypes.isEmpty {
                let remaining = BrowserContentRule.defaultResourceTypes.filter { !negatedTypes.contains($0) }
                return remaining.isEmpty ? .failure(.unsupportedType) : .success(remaining)
            }
            return .success(nil)
        }
    }

    // MARK: - Domains

    struct DomainList: Equatable {
        var include: [String] = []
        var exclude: [String] = []
    }

    /// `a.com|~b.com` (network) or `a.com,~b.com` (element hiding). An
    /// include WebKit can't take is dropped (the filter applies to fewer
    /// sites); an exclude it can't take skips the filter.
    static func domains(_ text: Substring, separator: Character) -> Result<DomainList, BrowserFilterSkipReason> {
        var list = DomainList()
        var droppedInclude: BrowserFilterSkipReason?
        for entry in text.split(separator: separator) {
            var item = entry.trimmingCharacters(in: .whitespaces)
            let negated = item.hasPrefix("~")
            if negated { item.removeFirst() }
            var domain = item.lowercased()
            while domain.hasSuffix(".") { domain.removeLast() }
            guard !domain.isEmpty else { continue }
            var problem: BrowserFilterSkipReason?
            if domain.contains("*") {
                problem = .entityDomain
            } else if !domain.unicodeScalars.allSatisfy(\.isASCII) {
                problem = .nonASCII
            } else if !domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) {
                problem = .malformed
            }
            if let problem {
                if negated { return .failure(problem) }
                droppedInclude = problem
                continue
            }
            if negated {
                list.exclude.append(domain)
            } else {
                list.include.append(domain)
            }
        }
        if list.include.isEmpty, let droppedInclude {
            return .failure(droppedInclude)
        }
        return .success(list)
    }

    /// WebKit's one domain condition for `list`: `if-domain` with the
    /// includes (excludes outside them don't matter), else
    /// `unless-domain`.
    static func condition(for list: DomainList) -> Result<BrowserContentRule.Condition?, BrowserFilterSkipReason> {
        var include = Set(list.include)
        let exclude = Set(list.exclude)
        guard !include.isEmpty else {
            return .success(exclude.isEmpty ? nil : .unlessDomain(exclude.sorted().map { "*" + $0 }))
        }
        for domain in exclude {
            if include.remove(domain) != nil { continue }
            if include.contains(where: { domain.hasSuffix("." + $0) }) {
                return .failure(.domainExceptionInsideInclude)
            }
            include = include.filter { !$0.hasSuffix("." + domain) }
        }
        guard !include.isEmpty else { return .failure(.malformed) }
        return .success(.ifDomain(include.sorted().map { "*" + $0 }))
    }

    // MARK: - Element hiding

    enum CosmeticMarker: String, CaseIterable {
        case hideException = "#@#"
        case extendedException = "#@?#"
        case snippetException = "#@$#"
        case extendedSnippetException = "#@$?#"
        case scriptException = "#@%#"
        case extendedSnippet = "#$?#"
        case hide = "##"
        case extended = "#?#"
        case snippet = "#$#"
        case script = "#%#"
        case html = "$$"
        case htmlException = "$@$"
    }

    private static let cosmeticMarkersLongestFirst = CosmeticMarker.allCases.sorted {
        $0.rawValue.count > $1.rawValue.count
    }

    /// `domains`, marker and body of an element-hiding (or other
    /// cosmetic) filter; nil for a network filter.
    static func cosmeticParts(_ line: Substring) -> (domains: Substring, marker: CosmeticMarker, body: Substring)? {
        // Longest markers first, so `#@$?#` isn't read as `#@`.
        let markers = cosmeticMarkersLongestFirst
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "#" || char == "$" {
                let rest = line[index...]
                if let marker = markers.first(where: { rest.hasPrefix($0.rawValue) }) {
                    let domains = line[..<index]
                    guard domains.allSatisfy(isDomainListCharacter) else { return nil }
                    let body = line[line.index(index, offsetBy: marker.rawValue.count)...]
                    return (domains, marker, body)
                }
            }
            guard isDomainListCharacter(char) else { return nil }
            index = line.index(after: index)
        }
        return nil
    }

    private static func isDomainListCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || ".-_~,*".contains(char)
    }

    static let proceduralOperators = [
        ":-abp-", ":has-text(", ":contains(", ":xpath(", ":upward(", ":matches-css", ":matches-path(",
        ":matches-attr(", ":matches-prop(", ":min-text-length(", ":watch-attr(", ":remove(", ":style(",
        ":remove-attr(", ":remove-class(", ":others(", ":if(", ":if-not(", ":nth-ancestor(", ":shadow(",
        ":matches-media(",
    ]

    /// Pseudo-classes and pseudo-elements WebKit's selector parser knows.
    static let pseudoNames: Set<String> = [
        "active", "any-link", "autofill", "checked", "default", "defined", "dir", "disabled", "empty",
        "enabled", "first-child", "first-of-type", "focus", "focus-visible", "focus-within", "fullscreen",
        "has", "hover", "in-range", "indeterminate", "invalid", "is", "lang", "last-child", "last-of-type",
        "link", "matches", "modal", "not", "nth-child", "nth-last-child", "nth-last-of-type", "nth-of-type",
        "only-child", "only-of-type", "optional", "out-of-range", "paused", "placeholder-shown", "playing",
        "read-only", "read-write", "required", "root", "scope", "target", "valid", "visited", "where",
        "-webkit-any", "-webkit-any-link", "-webkit-autofill", "after", "before", "first-letter",
        "first-line", "marker", "placeholder", "selection", "backdrop",
    ]

    /// Why WebKit would drop `selector` (it drops a whole batch for one
    /// bad selector), or nil.
    static func selectorProblem(_ selector: String) -> BrowserFilterSkipReason? {
        guard !selector.isEmpty else { return .malformed }
        let lowercased = selector.lowercased()
        if proceduralOperators.contains(where: { lowercased.contains($0) }) {
            return .procedural
        }
        let chars = Array(lowercased)
        var index = 0
        var quote: Character?
        var brackets = 0
        var parens = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                index += 2
                continue
            }
            if let open = quote {
                if char == open { quote = nil }
                index += 1
                continue
            }
            switch char {
            case "\"", "'": quote = char
            case "[": brackets += 1
            case "]":
                brackets -= 1
                if brackets < 0 { return .unsupportedSelector }
            case "(": parens += 1
            case ")":
                parens -= 1
                if parens < 0 { return .unsupportedSelector }
            case "{", "}", ";": return .unsupportedSelector
            case ":" where brackets == 0:
                var start = index + 1
                if start < chars.count, chars[start] == ":" { start += 1 }
                var end = start
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "-" || chars[end] == "_" {
                    end += 1
                }
                guard pseudoNames.contains(String(chars[start..<end])) else { return .unsupportedSelector }
                index = end
                continue
            default: break
            }
            index += 1
        }
        return quote == nil && brackets == 0 && parens == 0 ? nil : .unsupportedSelector
    }

    // MARK: - Conversion

    private struct SpecificHide {
        var domains: DomainList
        var selector: String
    }

    private struct Converter {
        var filterCount = 0
        var skipped: [BrowserFilterSkipReason: Int] = [:]
        var blocks: [BrowserContentRule] = []
        var important: [BrowserContentRule] = []
        var exceptions: [BrowserContentRule] = []
        var pageExceptions: [BrowserContentRule] = []
        var hideExceptions: [BrowserContentRule] = []
        var genericHideExceptions: [BrowserContentRule] = []
        /// Generic selectors in order, each with the domains every one of
        /// its filters leaves out (`~a.com##…`).
        var genericOrder: [String] = []
        var genericExclusions: [String: Set<String>] = [:]
        var specific: [SpecificHide] = []
        /// `#@#selector` without domains.
        var globalHideExceptions: Set<String> = []
        /// `a.com#@#selector`.
        var hideExceptionDomains: [String: Set<String>] = [:]

        mutating func skip(_ reason: BrowserFilterSkipReason, count: Int = 1) {
            skipped[reason, default: 0] += count
        }

        mutating func add(_ rawLine: Substring) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }
            filterCount += 1
            if let parts = BrowserFilterConverter.cosmeticParts(Substring(line)) {
                addCosmetic(parts)
            } else {
                addNetwork(Substring(line))
            }
        }

        mutating func addCosmetic(_ parts: (domains: Substring, marker: CosmeticMarker, body: Substring)) {
            switch parts.marker {
            case .extended, .extendedException: return skip(.extendedCSS)
            case .snippet, .snippetException, .extendedSnippet, .extendedSnippetException: return skip(.snippet)
            case .script, .scriptException: return skip(.adguardScript)
            case .html, .htmlException: return skip(.htmlFilter)
            case .hide, .hideException: break
            }
            let selector = parts.body.trimmingCharacters(in: .whitespaces)
            if selector.hasPrefix("+js(") { return skip(.scriptlet) }
            if selector.hasPrefix("^") { return skip(.htmlFilter) }
            if let problem = BrowserFilterConverter.selectorProblem(selector) { return skip(problem) }
            let domains: DomainList
            switch BrowserFilterConverter.domains(parts.domains, separator: ",") {
            case .success(let list): domains = list
            case .failure(let reason): return skip(reason)
            }
            if parts.marker == .hideException {
                if domains.include.isEmpty, domains.exclude.isEmpty {
                    globalHideExceptions.insert(selector)
                } else if domains.exclude.isEmpty {
                    hideExceptionDomains[selector, default: []].formUnion(domains.include)
                } else {
                    skip(.unsupportedDomainList)
                }
                return
            }
            if domains.include.isEmpty {
                let excluded = Set(domains.exclude)
                if let existing = genericExclusions[selector] {
                    // Another filter hides it on the sites this one leaves out.
                    genericExclusions[selector] = existing.intersection(excluded)
                } else {
                    genericOrder.append(selector)
                    genericExclusions[selector] = excluded
                }
            } else {
                specific.append(SpecificHide(domains: domains, selector: selector))
            }
        }

        mutating func addNetwork(_ line: Substring) {
            var text = line
            let isException = text.hasPrefix("@@")
            if isException { text = text.dropFirst(2) }
            let (pattern, optionsText) = BrowserFilterConverter.splitOptions(text)
            var options = NetworkOptions()
            for token in optionsText?.split(separator: ",") ?? [] {
                if let reason = options.apply(token) { return skip(reason) }
            }
            let urlFilter: String
            switch BrowserFilterConverter.urlFilter(for: pattern) {
            case .success(let filter): urlFilter = filter
            case .failure(let reason): return skip(reason)
            }
            var condition: BrowserContentRule.Condition?
            if let domainText = options.domains {
                switch BrowserFilterConverter.domains(domainText, separator: "|").flatMap(BrowserFilterConverter.condition(for:)) {
                case .success(let value): condition = value
                case .failure(let reason): return skip(reason)
                }
            }
            let types: [String]?
            switch options.resourceTypes() {
            case .success(let value): types = value
            case .failure(let reason):
                // `@@…$object,document` still excepts the page.
                guard isException, options.document || options.elemhide || options.generichide else {
                    return skip(reason)
                }
                types = nil
            }
            let loadType = options.thirdParty.map { $0 ? "third-party" : "first-party" }

            guard isException else {
                guard !options.elemhide, !options.generichide else { return skip(.malformed) }
                var rule = BrowserContentRule(
                    urlFilter: urlFilter,
                    caseSensitive: options.matchCase,
                    resourceTypes: types,
                    loadType: loadType,
                    condition: condition,
                    action: .block
                )
                if options.document {
                    // Whole pages, after the rule that lets pages through.
                    rule.resourceTypes = ((types ?? []) + ["document"]).sorted()
                    if types == nil {
                        rule.loadContext = "top-frame"
                    }
                    important.append(rule)
                } else if options.important {
                    rule.resourceTypes = rule.resourceTypes ?? BrowserContentRule.defaultResourceTypes
                    important.append(rule)
                } else {
                    rule.resourceTypes = rule.resourceTypes ?? BrowserContentRule.defaultResourceTypes
                    blocks.append(rule)
                }
                return
            }

            let pageWide = options.document || options.elemhide || options.generichide
            if pageWide {
                // The page itself: `if-top-url` with the pattern, or the
                // domains when the pattern matches everything.
                let pageCondition: BrowserContentRule.Condition
                if urlFilter == ".*" {
                    guard case .ifDomain? = condition, let condition else { return skip(.unsupportedDomainList) }
                    pageCondition = condition
                } else {
                    guard condition == nil else { return skip(.unsupportedDomainList) }
                    pageCondition = .ifTopURL([urlFilter])
                }
                let rule = BrowserContentRule(urlFilter: ".*", condition: pageCondition, action: .ignorePreviousRules)
                if options.document {
                    pageExceptions.append(rule)
                } else {
                    if options.elemhide { hideExceptions.append(rule) }
                    if options.generichide { genericHideExceptions.append(rule) }
                }
            }
            if !pageWide || !options.types.isEmpty {
                exceptions.append(BrowserContentRule(
                    urlFilter: urlFilter,
                    caseSensitive: options.matchCase,
                    resourceTypes: types ?? BrowserContentRule.defaultResourceTypes,
                    loadType: loadType,
                    condition: condition,
                    action: .ignorePreviousRules
                ))
            }
        }

        mutating func finish(maxRulesPerList: Int, selectorsPerRule: Int) -> BrowserFilterConversion {
            var lists: [[BrowserContentRule]] = []
            let letPagesThrough = BrowserContentRule(
                urlFilter: ".*",
                resourceTypes: ["document"],
                loadContext: "top-frame",
                action: .ignorePreviousRules
            )
            let network = BrowserRuleChunker.chunk([
                .split(blocks),
                .repeated(exceptions),
                .repeated([letPagesThrough]),
                .split(important),
                .repeated(pageExceptions),
            ], capacity: maxRulesPerList)
            lists += network.lists
            if network.dropped > 0 { skip(.tooManyExceptions, count: network.dropped) }

            let cosmetic = BrowserRuleChunker.chunk([
                .split(genericHideRules(selectorsPerRule: selectorsPerRule)),
                .repeated(genericHideExceptions),
                .split(specificHideRules(selectorsPerRule: selectorsPerRule)),
                .repeated(hideExceptions),
                .repeated(pageExceptions),
            ], capacity: maxRulesPerList)
            lists += cosmetic.lists
            if cosmetic.dropped > 0 { skip(.tooManyExceptions, count: cosmetic.dropped) }
            return BrowserFilterConversion(lists: lists, skipped: skipped, filterCount: filterCount)
        }

        /// Generic selectors batched per set of left-out domains (none
        /// first).
        private func genericHideRules(selectorsPerRule: Int) -> [BrowserContentRule] {
            var groups: [[String]: [String]] = [:]
            var order: [[String]] = []
            for selector in genericOrder where !globalHideExceptions.contains(selector) {
                let excluded = (genericExclusions[selector] ?? []).union(hideExceptionDomains[selector] ?? []).sorted()
                if groups[excluded] == nil {
                    order.append(excluded)
                }
                groups[excluded, default: []].append(selector)
            }
            order = order.filter(\.isEmpty) + order.filter { !$0.isEmpty }
            return order.flatMap { excluded in
                batches(groups[excluded] ?? [], size: selectorsPerRule).map {
                    BrowserContentRule(
                        urlFilter: ".*",
                        condition: excluded.isEmpty ? nil : .unlessDomain(excluded.map { "*" + $0 }),
                        action: .cssDisplayNone($0)
                    )
                }
            }
        }

        /// Domain-specific selectors batched per set of domains.
        private mutating func specificHideRules(selectorsPerRule: Int) -> [BrowserContentRule] {
            var groups: [[String]: [String]] = [:]
            var order: [[String]] = []
            for hide in specific where !globalHideExceptions.contains(hide.selector) {
                var domains = hide.domains
                domains.exclude += hideExceptionDomains[hide.selector] ?? []
                switch BrowserFilterConverter.condition(for: domains) {
                case .success(.ifDomain(let included)?):
                    if groups[included] == nil {
                        order.append(included)
                    }
                    groups[included, default: []].append(hide.selector)
                case .success:
                    continue
                case .failure(.malformed):
                    // Every one of its sites is excepted.
                    continue
                case .failure(let reason):
                    skip(reason)
                }
            }
            return order.flatMap { included in
                batches(groups[included] ?? [], size: selectorsPerRule).map {
                    BrowserContentRule(urlFilter: ".*", condition: .ifDomain(included), action: .cssDisplayNone($0))
                }
            }
        }

        private func batches(_ selectors: [String], size: Int) -> [[String]] {
            var seen: Set<String> = []
            let unique = selectors.filter { seen.insert($0).inserted }
            return stride(from: 0, to: unique.count, by: size).map {
                Array(unique[$0..<min($0 + size, unique.count)])
            }
        }
    }
}
