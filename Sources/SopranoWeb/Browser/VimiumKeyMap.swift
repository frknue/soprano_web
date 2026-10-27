import Foundation

enum VimiumHintMode: Equatable, Sendable {
    case currentTab
    case newTab
    case queue
    case copyLink
}

enum VimiumCommand: Equatable, Sendable {
    case scroll(dx: Double, dy: Double)
    case scrollPage(Int)
    case scrollToTop
    case scrollToBottom
    case scrollToLeft
    case scrollToRight
    case reload(hard: Bool)
    case copyCurrentURL
    case openCopied(newTab: Bool)
    case hints(VimiumHintMode)
    case find
    case findNext
    case findPrevious
    case findSelected(forward: Bool)
    case omnibar(newTab: Bool, edit: Bool)
    case bookmarks(newTab: Bool)
    case tabSearch
    case commandPalette
    case back
    case forward
    case nextTab
    case previousTab
    case firstTab
    case lastTab
    case previousVisitedTab
    case moveTabLeft
    case moveTabRight
    case moveTabToNewWindow
    case createTab
    case duplicateTab
    case closeTab
    case restoreTab
    case muteTab
    case zoomIn
    case zoomOut
    case zoomReset
    case insertMode
    case visual(line: Bool)
    case markSet
    case markJump
    case help
    case source
    case goUp(root: Bool)
    case previousLink
    case nextLink
    case focusInput
    case unsupported(String)
}

enum VimiumInputResult: Equatable {
    case handled
    case pending
    case execute(VimiumCommand, Int)
    case unknown
}

/// The normal-mode Vimium key map. Sequences are parsed here; the controller
/// owns mode state, hints, marks and the page scripts.
struct VimiumKeyMap {
    private(set) var prefix = ""
    private(set) var count = ""
    private let bindings: [String: VimiumCommand]
    private let prefixes: Set<String>

    init() {
        bindings = Self.defaultBindings
        prefixes = Self.makePrefixes(bindings)
    }

    var hasPendingInput: Bool {
        !prefix.isEmpty || !count.isEmpty
    }

    var pendingLabel: String {
        count + prefix
    }

    mutating func reset() {
        prefix = ""
        count = ""
    }

    mutating func feed(_ key: String) -> VimiumInputResult {
        guard !key.isEmpty else { return .unknown }

        if prefix.isEmpty, key.count == 1, let scalar = key.unicodeScalars.first,
           CharacterSet.decimalDigits.contains(scalar)
        {
            if key == "0" {
                guard !count.isEmpty else { return .unknown }
                count += key
                return .pending
            }
            count += key
            return .pending
        }

        let previousPrefix = prefix
        prefix += key

        if let command = bindings[prefix] {
            let value = max(1, Int(count) ?? 1)
            reset()
            return .execute(command, value)
        }
        if prefixes.contains(prefix) {
            return .pending
        }

        // A failed second key should consume the key and clear the sequence.
        if !previousPrefix.isEmpty {
            reset()
            return .unknown
        }

        reset()
        return .unknown
    }

    func command(for sequence: String) -> VimiumCommand? {
        bindings[sequence]
    }

    private static func makePrefixes(_ bindings: [String: VimiumCommand]) -> Set<String> {
        var result: Set<String> = []
        for key in bindings.keys {
            for end in 1..<key.count {
                result.insert(String(key.prefix(end)))
            }
        }
        return result
    }

    private static let defaultBindings: [String: VimiumCommand] = [
        "j": .scroll(dx: 0, dy: 60),
        "k": .scroll(dx: 0, dy: -60),
        "h": .scroll(dx: -60, dy: 0),
        "l": .scroll(dx: 60, dy: 0),
        "gg": .scrollToTop,
        "G": .scrollToBottom,
        "zH": .scrollToLeft,
        "zL": .scrollToRight,
        "d": .scrollPage(1),
        "u": .scrollPage(-1),
        "r": .reload(hard: false),
        "R": .reload(hard: true),
        "yy": .copyCurrentURL,
        "p": .openCopied(newTab: false),
        "P": .openCopied(newTab: true),
        "gi": .focusInput,
        "[[": .previousLink,
        "]]": .nextLink,
        "gf": .unsupported("Frame navigation is not available yet."),
        "gF": .unsupported("Frame navigation is not available yet."),
        "gu": .goUp(root: false),
        "gU": .goUp(root: true),
        "i": .insertMode,
        "v": .visual(line: false),
        "V": .visual(line: true),
        "f": .hints(.currentTab),
        "F": .hints(.newTab),
        "yf": .hints(.copyLink),
        "/": .find,
        "n": .findNext,
        "N": .findPrevious,
        "*": .findSelected(forward: true),
        "#": .findSelected(forward: false),
        "o": .omnibar(newTab: false, edit: false),
        "O": .omnibar(newTab: true, edit: false),
        "T": .tabSearch,
        "b": .bookmarks(newTab: false),
        "B": .bookmarks(newTab: true),
        ":": .commandPalette,
        "ge": .omnibar(newTab: false, edit: true),
        "gE": .omnibar(newTab: true, edit: true),
        "H": .back,
        "L": .forward,
        "K": .nextTab,
        "J": .previousTab,
        "gt": .nextTab,
        "gT": .previousTab,
        "^": .previousVisitedTab,
        "<<": .moveTabLeft,
        ">>": .moveTabRight,
        "g0": .firstTab,
        "g$": .lastTab,
        "W": .moveTabToNewWindow,
        "t": .createTab,
        "yt": .duplicateTab,
        "x": .closeTab,
        "X": .restoreTab,
        "zi": .zoomIn,
        "zo": .zoomOut,
        "z0": .zoomReset,
        "m": .markSet,
        "`": .markJump,
        "?": .help,
        "gs": .source,
    ]

    static let helpSections: [(title: String, rows: [(keys: String, action: String)])] = [
        ("Scrolling", [
            ("j / k", "scroll down / up"),
            ("h / l", "scroll left / right"),
            ("d / u", "half page down / up"),
            ("gg / G", "top / bottom"),
            ("zH / zL", "far left / right"),
            ("⌃E / ⌃Y", "line down / up"),
        ]),
        ("Hints", [
            ("f", "open a link"),
            ("F", "open a link in a new tab"),
            ("yf", "copy a link URL"),
            ("⌥F", "open multiple links"),
        ]),
        ("Find", [
            ("/", "find"),
            ("n / N", "next / previous match"),
            ("* / #", "find selected text forward / backward"),
        ]),
        ("Navigate", [
            ("o / O", "open URL in this / new tab"),
            ("b / B", "open bookmark in this / new tab"),
            ("T", "search open tabs"),
            (":", "Command Bar actions"),
            ("ge / gE", "edit URL in this / new tab"),
            ("H / L", "history back / forward"),
            ("gu / gU", "go up one level / to root"),
            ("[[ / ]]", "previous / next page link"),
            ("gf / gF", "frame navigation (not available)"),
        ]),
        ("Tabs", [
            ("J / K", "previous / next tab"),
            ("gT / gt", "previous / next tab"),
            ("g0 / g$", "first / last tab (count with g0)"),
            ("^", "previously visited tab"),
            ("<< / >>", "move tab left / right"),
            ("t / yt", "new / duplicated tab"),
            ("x / X", "close / restore tab"),
            ("W", "move tab to a new window"),
            ("⌥P", "not available"),
            ("⌥M", "mute / unmute tab"),
        ]),
        ("Other", [
            ("r / R", "reload / hard reload"),
            ("yy", "copy current URL"),
            ("p / P", "open clipboard in this / new tab"),
            ("gi", "focus first input"),
            ("i / Esc", "insert mode / leave it"),
            ("v / V", "visual / visual-line mode"),
            ("m / `", "set / jump to a mark"),
            ("``", "jump back"),
            ("zi / zo / z0", "zoom in / out / reset"),
            ("gs", "view DOM source"),
            ("?", "this help"),
        ]),
    ]

    static var helpText: String {
        helpSections.map { section in
            let rows = section.rows.map { row in
                "  " + row.keys.padding(toLength: 12, withPad: " ", startingAt: 0) + row.action
            }.joined(separator: "\n")
            return "\(section.title.uppercased())\n\(rows)"
        }.joined(separator: "\n\n")
    }
}
