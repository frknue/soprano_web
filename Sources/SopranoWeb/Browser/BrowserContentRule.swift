import Foundation

/// One WebKit content-blocker rule (`WKContentRuleList` JSON): a trigger
/// (`url-filter` and its options) and an action.
struct BrowserContentRule: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case block
        case ignorePreviousRules
        /// `css-display-none` with these selectors, joined with commas.
        case cssDisplayNone([String])
    }

    /// WebKit allows at most one of these per trigger.
    enum Condition: Hashable, Sendable {
        /// The top-level page's domain; values are `*domain` (the domain
        /// and its subdomains).
        case ifDomain([String])
        case unlessDomain([String])
        /// Regular expressions matched against the top-level page's URL.
        case ifTopURL([String])
    }

    var urlFilter: String
    var caseSensitive = false
    /// WebKit `resource-type` names; nil matches every type.
    var resourceTypes: [String]?
    /// `first-party` or `third-party`; nil matches both.
    var loadType: String?
    /// `top-frame` or `child-frame`; nil matches both.
    var loadContext: String?
    var condition: Condition?
    var action: Action

    /// Every `resource-type` an Adblock Plus filter without type options
    /// applies to: everything but pop-ups. WebKit's `document` covers
    /// frames; the network lists' last rules let top-level pages through.
    static let defaultResourceTypes = [
        "document", "fetch", "font", "image", "media", "other", "ping", "script", "style-sheet",
        "svg-document", "websocket",
    ]

    /// Encodes `rules` as the JSON array `WKContentRuleListStore` compiles.
    static func json(_ rules: [BrowserContentRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension BrowserContentRule: Encodable {
    private enum Key: String, CodingKey {
        case trigger
        case action
        case type
        case selector
        case urlFilter = "url-filter"
        case caseSensitive = "url-filter-is-case-sensitive"
        case resourceType = "resource-type"
        case loadType = "load-type"
        case loadContext = "load-context"
        case ifDomain = "if-domain"
        case unlessDomain = "unless-domain"
        case ifTopURL = "if-top-url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        var trigger = container.nestedContainer(keyedBy: Key.self, forKey: .trigger)
        try trigger.encode(urlFilter, forKey: .urlFilter)
        if caseSensitive {
            try trigger.encode(true, forKey: .caseSensitive)
        }
        if let resourceTypes {
            try trigger.encode(resourceTypes, forKey: .resourceType)
        }
        if let loadType {
            try trigger.encode([loadType], forKey: .loadType)
        }
        if let loadContext {
            try trigger.encode([loadContext], forKey: .loadContext)
        }
        switch condition {
        case .ifDomain(let domains): try trigger.encode(domains, forKey: .ifDomain)
        case .unlessDomain(let domains): try trigger.encode(domains, forKey: .unlessDomain)
        case .ifTopURL(let patterns): try trigger.encode(patterns, forKey: .ifTopURL)
        case nil: break
        }
        var action = container.nestedContainer(keyedBy: Key.self, forKey: .action)
        switch self.action {
        case .block:
            try action.encode("block", forKey: .type)
        case .ignorePreviousRules:
            try action.encode("ignore-previous-rules", forKey: .type)
        case .cssDisplayNone(let selectors):
            try action.encode("css-display-none", forKey: .type)
            try action.encode(selectors.joined(separator: ", "), forKey: .selector)
        }
    }
}

/// Splits rules into lists of at most `capacity` rules. Rules in a
/// `repeated` segment (exceptions) only reach rules of their own list, so
/// every list gets a copy; `split` segments are spread over the lists in
/// order. Each list keeps the segments' order.
enum BrowserRuleChunker {
    enum Segment: Equatable {
        case split([BrowserContentRule])
        case repeated([BrowserContentRule])
    }

    /// The lists, and how many `split` rules found no room (when the
    /// repeated rules alone fill a list).
    static func chunk(_ segments: [Segment], capacity: Int) -> (lists: [[BrowserContentRule]], dropped: Int) {
        var repeatedCount = 0
        var splitCount = 0
        for segment in segments {
            switch segment {
            case .split(let rules): splitCount += rules.count
            case .repeated(let rules): repeatedCount += rules.count
            }
        }
        guard splitCount > 0 else { return ([], 0) }
        let room = capacity - repeatedCount
        guard room > 0 else { return ([], splitCount) }

        let listCount = (splitCount + room - 1) / room
        var lists: [[BrowserContentRule]] = []
        lists.reserveCapacity(listCount)
        for list in 0..<listCount {
            let range = (list * room)..<min((list + 1) * room, splitCount)
            var rules: [BrowserContentRule] = []
            rules.reserveCapacity(range.count + repeatedCount)
            var offset = 0
            for segment in segments {
                switch segment {
                case .repeated(let segmentRules):
                    rules += segmentRules
                case .split(let segmentRules):
                    let segmentRange = offset..<(offset + segmentRules.count)
                    let taken = segmentRange.clamped(to: range)
                    if !taken.isEmpty {
                        rules += segmentRules[(taken.lowerBound - offset)..<(taken.upperBound - offset)]
                    }
                    offset += segmentRules.count
                }
            }
            lists.append(rules)
        }
        return (lists, 0)
    }
}
