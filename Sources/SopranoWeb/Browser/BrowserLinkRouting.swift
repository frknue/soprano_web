import Foundation

// MARK: - Rules

/// One "Links from other apps" rule (Arc's Air Traffic Control): a link
/// another app opens whose address matches `value` opens in `destination`.
struct BrowserLinkRoutingRule: Codable, Equatable, Identifiable, Sendable {
    enum Match: String, Codable, CaseIterable, Sendable {
        /// The address contains `value`.
        case contains
        /// The address is `value`.
        case equals
        /// The address starts with `value`.
        case prefix

        var title: String {
            switch self {
            case .contains: "contains"
            case .equals: "is"
            case .prefix: "starts with"
            }
        }
    }

    enum Destination: Equatable, Sendable {
        /// The most recently active window's current Space (what any other
        /// link gets; a rule saying so keeps the link out of a later rule).
        case mostRecentSpace
        /// That Space; a link opens in a window showing it, else the most
        /// recent window switches to it.
        case space(UUID)
    }

    var id: UUID
    var match: Match
    /// Compared case-insensitively. Without a scheme it is matched against
    /// the address without its scheme too (`meet.google.com`).
    var value: String
    var destination: Destination
    /// Where an import made it (`arc`).
    var importedFrom: String?

    init(
        id: UUID = UUID(),
        match: Match,
        value: String,
        destination: Destination,
        importedFrom: String? = nil
    ) {
        self.id = id
        self.match = match
        self.value = value
        self.destination = destination
        self.importedFrom = importedFrom
    }

    /// Whether `address` (a link from another app) matches.
    func matches(_ address: String) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        let full = address.lowercased()
        var candidates = [full]
        if !needle.contains("://"), let range = full.range(of: "://") {
            candidates.append(String(full[range.upperBound...]))
        }
        return candidates.contains { candidate in
            switch match {
            case .contains:
                return candidate.contains(needle)
            case .prefix:
                return candidate.hasPrefix(needle)
            case .equals:
                return Self.trimmingSlash(candidate) == Self.trimmingSlash(needle)
            }
        }
    }

    /// The same rule (another id): what an import skips.
    func isSameRule(as other: BrowserLinkRoutingRule) -> Bool {
        match == other.match
            && value.lowercased() == other.value.lowercased()
            && destination == other.destination
    }

    private static func trimmingSlash(_ text: String) -> String {
        text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    private enum CodingKeys: String, CodingKey {
        case id, match, value, space, importedFrom
    }

    /// A rule needs an id, a known match and a value; `space` absent is the
    /// most recent Space.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        guard let match = Match(rawValue: try c.decode(String.self, forKey: .match)) else {
            throw DecodingError.dataCorruptedError(forKey: .match, in: c, debugDescription: "unknown match")
        }
        self.match = match
        value = try c.decode(String.self, forKey: .value)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "empty value")
        }
        destination = ((try? c.decodeIfPresent(UUID.self, forKey: .space)) ?? nil).map(Destination.space) ?? .mostRecentSpace
        importedFrom = (try? c.decodeIfPresent(String.self, forKey: .importedFrom)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(match.rawValue, forKey: .match)
        try c.encode(value, forKey: .value)
        if case let .space(id) = destination {
            try c.encode(id, forKey: .space)
        }
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
    }
}

/// The routing decision for links from other apps: the first rule that
/// matches wins; nil means no rule matched (the most recent window).
enum BrowserLinkRouting {
    static func rule(for address: String, in rules: [BrowserLinkRoutingRule]) -> BrowserLinkRoutingRule? {
        rules.first { $0.matches(address) }
    }
}

/// `link-routing.json`: `{ "version": 1, "rules": [{ "id", "match":
/// "contains" | "equals" | "prefix", "value", "space"?, "importedFrom"? }] }`.
/// Decoding is tolerant: a rule that does not decode is skipped and a
/// repeated id keeps its first rule.
struct BrowserLinkRoutingFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var rules: [BrowserLinkRoutingRule]

    init(rules: [BrowserLinkRoutingRule]) {
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case version, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? c.decodeIfPresent(LossyArray<BrowserLinkRoutingRule>.self, forKey: .rules))?.elements ?? []
        var seen: Set<UUID> = []
        rules = decoded.filter { seen.insert($0.id).inserted }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(rules, forKey: .rules)
    }
}

// MARK: - Store

/// The rules for links from other apps, saved to `link-routing.json`
/// (support folder) after each change and announced on `changes`. Rules
/// come from an import; Settings ▸ Links from other apps lists and deletes
/// them.
@MainActor
final class BrowserLinkRoutingStore {
    let url: URL
    let changes = BrowserObservers<Void>()
    private(set) var rules: [BrowserLinkRoutingRule]

    init(url: URL = BrowserFiles.supportDirectory().appendingPathComponent("link-routing.json")) {
        self.url = url
        rules = JSONFile.read(BrowserLinkRoutingFile.self, at: url)?.rules ?? []
    }

    func rule(for address: String) -> BrowserLinkRoutingRule? {
        BrowserLinkRouting.rule(for: address, in: rules)
    }

    /// Appends the rules that are not already there (`isSameRule`);
    /// returns how many were added.
    @discardableResult
    func add(_ newRules: [BrowserLinkRoutingRule]) -> Int {
        var added: [BrowserLinkRoutingRule] = []
        for rule in newRules where !(rules + added).contains(where: { $0.isSameRule(as: rule) || $0.id == rule.id }) {
            added.append(rule)
        }
        guard !added.isEmpty else { return 0 }
        rules += added
        commit()
        return added.count
    }

    func remove(id: UUID) {
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return }
        commit()
    }

    /// An import's rules (`importedFrom` == `source`) in the source's order:
    /// rules already there keep their ids, new ones join, and the imported
    /// block is rebuilt in that order where it stood (rules a former import
    /// brought that this one doesn't follow it), so first-match order stays
    /// the source's across re-imports. Returns how many were added.
    @discardableResult
    func mergeImported(_ incoming: [BrowserLinkRoutingRule], from source: String) -> Int {
        let earlier = rules.filter { $0.importedFrom == source }
        let others = rules.filter { $0.importedFrom != source }
        var block: [BrowserLinkRoutingRule] = []
        var added = 0
        for rule in incoming where !block.contains(where: { $0.isSameRule(as: rule) })
            && !others.contains(where: { $0.isSameRule(as: rule) })
        {
            if let kept = earlier.first(where: { $0.isSameRule(as: rule) }) {
                block.append(kept)
            } else {
                var new = rule
                new.importedFrom = source
                block.append(new)
                added += 1
            }
        }
        block += earlier.filter { rule in !block.contains { $0.id == rule.id } }
        let position = rules.firstIndex { $0.importedFrom == source }
            .map { index in rules[..<index].filter { $0.importedFrom != source }.count } ?? others.count
        var next = others
        next.insert(contentsOf: block, at: position)
        guard next != rules else { return 0 }
        rules = next
        commit()
        return added
    }

    private func commit() {
        try? JSONFile.write(BrowserLinkRoutingFile(rules: rules), to: url)
        changes.notify()
    }
}
