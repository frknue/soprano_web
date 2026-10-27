import Foundation

/// The pure rules of pinned and favorite live tabs (Arc's model): a tab
/// linked to a pin of its Space or a favorite of its profile
/// (`BrowserTabOrigin`), when it shows the "/" mark, what becomes of the
/// link when the pin goes or the tab moves, and the order the tab lists
/// show a Space's tabs in.
enum BrowserPinLinks {
    /// What a link is checked against: the pins of the tab's Space and the
    /// favorites of its profile, by id.
    struct Targets: Equatable, Sendable {
        var pins: Set<UUID>
        var favorites: Set<UUID>

        init(pins: Set<UUID> = [], favorites: Set<UUID> = []) {
            self.pins = pins
            self.favorites = favorites
        }

        func contains(_ origin: BrowserTabOrigin) -> Bool {
            switch origin {
            case .today: true
            case let .pinned(id): pins.contains(id)
            case let .favorite(id): favorites.contains(id)
            }
        }
    }

    /// The link while its pin or favorite still exists; a Today tab once
    /// it is gone (the pin was deleted, the session names one that is no
    /// longer there).
    static func validated(_ origin: BrowserTabOrigin, in targets: Targets) -> BrowserTabOrigin {
        targets.contains(origin) ? origin : .today
    }

    /// The link a tab keeps when it moves into a window (a drop, Move Tab
    /// to New Window, Merge All Windows): it stays linked only while its
    /// pin or favorite exists where it lands (`targets`: the pins of the
    /// Space it lands in, the favorites of that Space's profile) and the
    /// window has no live tab for it yet (`live`: the links of the tabs
    /// already there); otherwise it lands as a Today tab.
    static func originAfterMove(
        _ origin: BrowserTabOrigin,
        into targets: Targets,
        live: [BrowserTabOrigin]
    ) -> BrowserTabOrigin {
        guard origin != .today, targets.contains(origin), !live.contains(origin) else { return .today }
        return origin
    }

    /// Whether a linked tab's page (`address`, nil while it has none) left
    /// its pin: the "/" mark, and what clicking the pin's icon resets. The
    /// tab is home on the pin's address and on `landing`, where the last
    /// load of the pin ended up (a redirect: `http` to `https`, `/docs` to
    /// `/docs/`, a site's own start page). Scheme and host case, a default
    /// port, an empty path, a trailing "/" and the fragment don't count.
    static func isAway(_ address: String?, from pinURL: String, landing: String? = nil) -> Bool {
        guard let address else { return false }
        let page = normalized(address)
        return page != normalized(pinURL) && page != landing.map(normalized)
    }

    /// `address` as `isAway` compares it.
    static func normalized(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        switch (components.scheme, components.port) {
        case ("http", 80), ("https", 443):
            components.port = nil
        default:
            break
        }
        if components.host != nil, components.path.isEmpty {
            components.path = "/"
        } else if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed
    }

    /// The order a Space's live tabs show in (the tab strip, and what
    /// ⌘1…⌘9, Vimium `gt` and the CLI's tab numbers count): favorite tabs
    /// in the favorites' order, then pinned tabs in the pinned tree's
    /// order, then Today tabs in window order. A link to an id in neither
    /// list counts as Today.
    static func order<ID>(
        _ tabs: [(id: ID, origin: BrowserTabOrigin)],
        favorites: [UUID],
        pins: [UUID]
    ) -> [ID] {
        let favoriteRank = Dictionary(favorites.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let pinRank = Dictionary(pins.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func rank(_ origin: BrowserTabOrigin) -> (group: Int, index: Int) {
            switch origin {
            case let .favorite(id):
                if let index = favoriteRank[id] { return (0, index) }
            case let .pinned(id):
                if let index = pinRank[id] { return (1, index) }
            case .today:
                break
            }
            return (2, 0)
        }
        return tabs.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element.origin)
                let right = rank(rhs.element.origin)
                if left.group != right.group { return left.group < right.group }
                if left.index != right.index { return left.index < right.index }
                return lhs.offset < rhs.offset
            }
            .map(\.element.id)
    }
}

extension BrowserSpaceIcon {
    /// What the New Space sheet's icon field means: empty is no icon, an SF
    /// Symbol name (`isSymbol` says which exist) is that symbol, anything
    /// else is its first character as an emoji.
    static func parse(_ text: String, isSymbol: (String) -> Bool) -> BrowserSpaceIcon {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return .none }
        if trimmed.allSatisfy({ $0.isASCII }), isSymbol(trimmed) {
            return .symbol(trimmed)
        }
        return .emoji(String(first))
    }

    /// The text the icon field shows for this icon.
    var fieldText: String {
        switch self {
        case .none: ""
        case let .emoji(value): value
        case let .symbol(name): name
        }
    }
}

extension BrowserSpaceList {
    /// What a tab of `space` may be linked to: its pins, its profile's
    /// favorites.
    func linkTargets(of space: BrowserSpace) -> BrowserPinLinks.Targets {
        BrowserPinLinks.Targets(
            pins: Set(space.pinned.root.allPins.map(\.id)),
            favorites: Set(favorites(ofProfile: space.profileID).items.map(\.id))
        )
    }
}
