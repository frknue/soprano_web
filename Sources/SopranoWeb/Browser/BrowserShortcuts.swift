import AppKit

// MARK: - Shortcut

/// One keyboard shortcut: a key and its modifiers. `key` is a lowercased
/// character (`c`, `1`, `[`, `=`, `,`) or a named key (`tab`, `return`,
/// `delete`, `escape`, `space`, `up`, `down`, `left`, `right`, `f1`…`f12`).
/// Saved in `settings.json` as `"shift+cmd+c"`; shown as `⇧⌘C`.
struct BrowserShortcut: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    static let namedKeys: Set<String> = Set([
        "tab", "return", "delete", "forwarddelete", "escape", "space", "up", "down", "left", "right",
        "home", "end", "pageup", "pagedown",
    ]).union((1...12).map { "f\($0)" })

    /// The shifted characters of a US keyboard and their keys, so `⇧⌘[`
    /// typed as `{` is still `[`.
    private static let unshifted: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "{": "[", "}": "]", "+": "=", "_": "-", "<": ",", ">": ".", "?": "/", ":": ";", "\"": "'",
        "|": "\\", "~": "`",
    ]

    /// Parses `"shift+cmd+c"` (any order; `cmd`/`command`/`⌘`,
    /// `opt`/`option`/`alt`/`⌥`, `ctrl`/`control`/`⌃`, `shift`/`⇧`) or the
    /// display form `"⇧⌘C"`. Nil when there is no single key.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var modifiers: Modifiers = []
        var rest = Substring(trimmed)
        // The symbol form: modifier glyphs, then the key.
        while let first = rest.first, let modifier = Self.symbolModifier(first), rest.count > 1 {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        var keyText = String(rest)
        if rest.count > 1, rest.contains("+") {
            var parts = rest.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            keyText = parts.removeLast()
            if keyText.isEmpty, parts.last?.isEmpty == true {
                // "cmd++": the plus key.
                parts.removeLast()
                keyText = "+"
            }
            for word in parts {
                guard let modifier = Self.wordModifier(word.lowercased()) else { return nil }
                modifiers.insert(modifier)
            }
        }
        guard let key = Self.normalizedKey(keyText, modifiers: &modifiers) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    private static func symbolModifier(_ character: Character) -> Modifiers? {
        switch character {
        case "⌃": .control
        case "⌥": .option
        case "⇧": .shift
        case "⌘": .command
        default: nil
        }
    }

    private static func wordModifier(_ word: String) -> Modifiers? {
        switch word {
        case "ctrl", "control", "⌃": .control
        case "opt", "option", "alt", "⌥": .option
        case "shift", "⇧": .shift
        case "cmd", "command", "⌘": .command
        default: nil
        }
    }

    /// The key as saved: lowercased, a display glyph or name back to its
    /// name, a shifted character back to its key with shift.
    private static func normalizedKey(_ raw: String, modifiers: inout Modifiers) -> String? {
        let lowered = raw.lowercased()
        switch lowered {
        case "⇥", "tab": return "tab"
        case "↩", "↵", "return", "enter": return "return"
        case "⌫", "delete", "backspace": return "delete"
        case "⌦", "forwarddelete": return "forwarddelete"
        case "⎋", "esc", "escape": return "escape"
        case "space", "␣": return "space"
        case "↑", "up": return "up"
        case "↓", "down": return "down"
        case "←", "left": return "left"
        case "→", "right": return "right"
        case "plus": return "="
        default: break
        }
        if namedKeys.contains(lowered) { return lowered }
        guard lowered.count == 1, let character = lowered.first else { return nil }
        if let key = unshifted[character] {
            modifiers.insert(.shift)
            return key
        }
        guard !character.isWhitespace else { return nil }
        return String(character)
    }

    /// `"shift+cmd+c"`: the form `settings.json` keeps.
    var storageText: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("ctrl") }
        if modifiers.contains(.option) { words.append("opt") }
        if modifiers.contains(.shift) { words.append("shift") }
        if modifiers.contains(.command) { words.append("cmd") }
        return (words + [key]).joined(separator: "+")
    }

    /// `⇧⌘C`, `⌃Tab`, `⌥⌘↓`: what menus, Settings and the Command Bar show.
    var display: String {
        modifierGlyphs + keyGlyph
    }

    var modifierGlyphs: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    var keyGlyph: String {
        switch key {
        case "tab": "Tab"
        case "return": "↩"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "escape": "Esc"
        case "space": "Space"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }

    /// A shortcut the app can own: it has ⌘ or ⌃, or ⌥ with a key that
    /// types nothing (arrows, Tab, function keys).
    var isAssignable: Bool {
        if modifiers.contains(.command) || modifiers.contains(.control) { return true }
        return modifiers.contains(.option) && Self.namedKeys.contains(key) && key != "space"
    }

    /// Keys outside the registry the app must leave alone, with who owns
    /// them: the Edit menu's standard submenus, the system's window and
    /// input shortcuts, the Cocoa text-editing bindings every field uses,
    /// and Vimium's ⌃ keys. Recording or decoding one is refused.
    static func reservedOwner(of shortcut: BrowserShortcut) -> String? {
        reserved[shortcut]
    }

    private static let reserved: [BrowserShortcut: String] = {
        var table: [BrowserShortcut: String] = [:]
        func add(_ owner: String, _ texts: [String]) {
            for text in texts {
                if let shortcut = BrowserShortcut(text) { table[shortcut] = owner }
            }
        }
        add("Edit ▸ Spelling and Grammar", ["cmd+;", "shift+cmd+;"])
        add("the system (Cycle Windows)", ["cmd+`", "shift+cmd+`"])
        add("the system (Emoji & Symbols)", ["ctrl+cmd+space"])
        add("Help ▸ Search", ["shift+cmd+/"])
        add("text editing", [
            "ctrl+a", "ctrl+b", "ctrl+d", "ctrl+f", "ctrl+h", "ctrl+k", "ctrl+n", "ctrl+o", "ctrl+p", "ctrl+t",
            "ctrl+v", "opt+delete", "cmd+delete", "opt+forwarddelete",
            "opt+left", "opt+right", "opt+up", "opt+down",
            "shift+opt+left", "shift+opt+right", "shift+opt+up", "shift+opt+down",
            "cmd+left", "cmd+right", "cmd+up", "cmd+down",
            "shift+cmd+left", "shift+cmd+right", "shift+cmd+up", "shift+cmd+down",
        ])
        // Vimium's normal mode reads these before the page.
        add("Vimium", ["ctrl+e", "ctrl+y", "ctrl+["])
        return table
    }()

    // MARK: AppKit

    /// The menu item's `keyEquivalent`.
    var keyEquivalent: String {
        func function(_ value: Int) -> String { String(Character(UnicodeScalar(UInt16(value))!)) }
        switch key {
        case "tab": return "\t"
        case "return": return "\r"
        case "delete": return "\u{8}"
        case "forwarddelete": return function(NSDeleteFunctionKey)
        case "escape": return "\u{1b}"
        case "space": return " "
        case "up": return function(NSUpArrowFunctionKey)
        case "down": return function(NSDownArrowFunctionKey)
        case "left": return function(NSLeftArrowFunctionKey)
        case "right": return function(NSRightArrowFunctionKey)
        case "home": return function(NSHomeFunctionKey)
        case "end": return function(NSEndFunctionKey)
        case "pageup": return function(NSPageUpFunctionKey)
        case "pagedown": return function(NSPageDownFunctionKey)
        default:
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...12).contains(number) {
                return function(NSF1FunctionKey + number - 1)
            }
            // ⇧ with punctuation or a digit: the menu keys on the shifted
            // character (⌘{, ⌘?), as AppKit's own items do.
            if modifiers.contains(.shift), let shifted = Self.shifted[key] {
                return shifted
            }
            return key
        }
    }

    /// `unshifted` the other way round.
    private static let shifted: [String: String] = Dictionary(
        unshifted.map { (String($0.value), String($0.key)) },
        uniquingKeysWith: { first, _ in first }
    )

    var modifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        // The shifted character carries ⇧ already.
        if modifiers.contains(.shift), Self.shifted[key] == nil { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// The shortcut a key-down event is. Named keys come from the key code;
    /// characters from the event ignoring modifiers but shift, mapped back
    /// to their unshifted key.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if let named = Self.namedKey(keyCode: event.keyCode) {
            self.init(named, modifiers)
            return
        }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else { return nil }
        if let scalar = characters.unicodeScalars.first, let named = Self.namedKey(function: Int(scalar.value)) {
            self.init(named, modifiers)
            return
        }
        guard let key = Self.normalizedKey(characters, modifiers: &modifiers) else { return nil }
        self.init(key, modifiers)
    }

    private static func namedKey(keyCode: UInt16) -> String? {
        switch keyCode {
        case 48: "tab"
        case 36, 76: "return"
        case 51: "delete"
        case 117: "forwarddelete"
        case 53: "escape"
        case 49: "space"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 115: "home"
        case 119: "end"
        case 116: "pageup"
        case 121: "pagedown"
        case 122: "f1"
        case 120: "f2"
        case 99: "f3"
        case 118: "f4"
        case 96: "f5"
        case 97: "f6"
        case 98: "f7"
        case 100: "f8"
        case 101: "f9"
        case 109: "f10"
        case 103: "f11"
        case 111: "f12"
        default: nil
        }
    }

    private static func namedKey(function value: Int) -> String? {
        switch value {
        case 0x09, 0x19: "tab"
        case NSUpArrowFunctionKey: "up"
        case NSDownArrowFunctionKey: "down"
        case NSLeftArrowFunctionKey: "left"
        case NSRightArrowFunctionKey: "right"
        default: nil
        }
    }

    /// The shortcut a page's `keydown` was, from `KeyboardEvent.code` (the
    /// physical key; `key` changes with ⌥ and the layout).
    init?(domCode code: String, meta: Bool, ctrl: Bool, alt: Bool, shift: Bool) {
        var modifiers: Modifiers = []
        if ctrl { modifiers.insert(.control) }
        if alt { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if meta { modifiers.insert(.command) }
        let key: String?
        if code.hasPrefix("Key"), code.count == 4 {
            key = code.suffix(1).lowercased()
        } else if code.hasPrefix("Digit"), code.count == 6 {
            key = String(code.suffix(1))
        } else if code.hasPrefix("F"), let number = Int(code.dropFirst()), (1...12).contains(number) {
            key = "f\(number)"
        } else {
            key = Self.domKeys[code]
        }
        guard let key else { return nil }
        self.init(key, modifiers)
    }

    private static let domKeys: [String: String] = [
        "Tab": "tab", "Enter": "return", "NumpadEnter": "return", "Backspace": "delete", "Delete": "forwarddelete",
        "Escape": "escape", "Space": "space", "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left",
        "ArrowRight": "right", "Home": "home", "End": "end", "PageUp": "pageup", "PageDown": "pagedown",
        "BracketLeft": "[", "BracketRight": "]", "Minus": "-", "Equal": "=", "Comma": ",", "Period": ".",
        "Slash": "/", "Semicolon": ";", "Quote": "'", "Backquote": "`", "Backslash": "\\",
    ]
}

// MARK: - Priority

/// Who gets a shortcut first while a page has keyboard focus (Arc's
/// Settings ▸ Shortcuts): the app, the site (the app runs it only when the
/// page didn't `preventDefault` the key), or the site unless pressed twice
/// within `BrowserShortcutGate.pressTwiceInterval`.
enum BrowserShortcutPriority: String, Codable, CaseIterable, Sendable {
    case app
    case site
    case twice

    var title: String {
        switch self {
        case .app: "App wins"
        case .site: "Site wins"
        case .twice: "Press twice"
        }
    }
}

// MARK: - Settings

/// `shortcuts` in `settings.json`: per command id, a remapped shortcut
/// (`"none"` removes it) and the priority; only what differs from the
/// defaults is kept. Decoded entry by entry: an unknown or fixed command, a
/// bad shortcut or an unknown priority drops only that part.
struct BrowserShortcutSettings: Codable, Equatable, Sendable {
    enum Binding: Equatable, Sendable {
        case shortcut(BrowserShortcut)
        case none
    }

    struct Entry: Equatable, Sendable {
        /// Nil keeps the default shortcut.
        var binding: Binding?
        var priority: BrowserShortcutPriority = .app

        var isDefault: Bool { binding == nil && priority == .app }
    }

    private(set) var entries: [BrowserCommandID: Entry] = [:]

    init(entries: [BrowserCommandID: Entry] = [:]) {
        self.entries = entries.filter { !$0.value.isDefault }
    }

    subscript(id: BrowserCommandID) -> Entry {
        get { entries[id] ?? Entry() }
        set { entries[id] = newValue.isDefault ? nil : newValue }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum EntryKeys: String, CodingKey {
        case shortcut, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for key in container.allKeys {
            guard let id = BrowserCommandID(rawValue: key.stringValue), id.isRemappable,
                  let entry = try? container.nestedContainer(keyedBy: EntryKeys.self, forKey: key)
            else { continue }
            var value = Entry()
            if let text = try? entry.decodeIfPresent(String.self, forKey: .shortcut) {
                if text.lowercased() == "none" {
                    value.binding = Binding.none
                } else if let shortcut = BrowserShortcut(text), shortcut.isAssignable,
                          BrowserShortcut.reservedOwner(of: shortcut) == nil
                {
                    value.binding = .shortcut(shortcut)
                }
            }
            value.priority = (try? entry.decodeIfPresent(BrowserShortcutPriority.self, forKey: .priority)) ?? .app
            self[id] = value
        }
        resolveCollisions()
    }

    /// What `assign` would never have saved: a remap onto a fixed command's
    /// key is dropped (the default comes back), and of two commands with the
    /// same key the later one in registry order gets none.
    private mutating func resolveCollisions() {
        let fixed = Set(BrowserCommandID.allCases.filter { !$0.isRemappable }.compactMap(\.defaultShortcut))
        for (id, entry) in entries {
            if case let .shortcut(shortcut)? = entry.binding, fixed.contains(shortcut) {
                self[id].binding = nil
            }
        }
        var used = fixed
        for id in BrowserCommandID.allCases where id.isRemappable {
            let shortcut: BrowserShortcut?
            switch self[id].binding {
            case let .shortcut(remapped)?: shortcut = remapped
            case .none?: shortcut = nil
            case nil: shortcut = id.defaultShortcut
            }
            guard let shortcut else { continue }
            if used.contains(shortcut) {
                self[id].binding = Binding.none
            } else {
                used.insert(shortcut)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (id, entry) in entries.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var nested = container.nestedContainer(keyedBy: EntryKeys.self, forKey: DynamicKey(stringValue: id.rawValue))
            switch entry.binding {
            case let .shortcut(shortcut)?: try nested.encode(shortcut.storageText, forKey: .shortcut)
            case .none?: try nested.encode("none", forKey: .shortcut)
            case nil: break
            }
            if entry.priority != .app {
                try nested.encode(entry.priority, forKey: .priority)
            }
        }
    }
}

// MARK: - Keymap

/// The shortcuts in effect: the registry's defaults with the user's
/// remapping on top. The one place that answers which command a key is,
/// which shortcut a command has, and what a new assignment collides with.
struct BrowserKeymap: Equatable, Sendable {
    private(set) var settings: BrowserShortcutSettings

    init(_ settings: BrowserShortcutSettings = BrowserShortcutSettings()) {
        self.settings = settings
    }

    func shortcut(for id: BrowserCommandID) -> BrowserShortcut? {
        guard id.isRemappable, let binding = settings[id].binding else { return id.defaultShortcut }
        switch binding {
        case let .shortcut(shortcut): return shortcut
        case .none: return nil
        }
    }

    func priority(for id: BrowserCommandID) -> BrowserShortcutPriority {
        settings[id].priority
    }

    func isCustomized(_ id: BrowserCommandID) -> Bool {
        !settings[id].isDefault
    }

    /// The command `shortcut` runs (the first in registry order).
    func command(for shortcut: BrowserShortcut) -> BrowserCommandID? {
        BrowserCommandID.allCases.first { self.shortcut(for: $0) == shortcut }
    }

    enum Assignment: Equatable, Sendable {
        case assigned
        /// Another command has the shortcut; `swap: true` trades.
        case conflict(BrowserCommandID)
        /// A fixed command (Quit, Copy, …) has it.
        case refused(BrowserCommandID)
        /// The system, text editing or Vimium uses it (`reservedOwner`).
        case reserved(String)
        /// No ⌘ or ⌃ (or ⌥ with a key that types nothing).
        case invalid
    }

    /// Gives `id` the shortcut (nil: none). A shortcut another command has
    /// is a conflict; with `swap` the other command takes `id`'s current
    /// shortcut (or none). A fixed command's shortcut is refused.
    @discardableResult
    mutating func assign(_ shortcut: BrowserShortcut?, to id: BrowserCommandID, swap: Bool = false) -> Assignment {
        guard id.isRemappable else { return .refused(id) }
        if let shortcut {
            guard shortcut.isAssignable else { return .invalid }
            if let owner = BrowserShortcut.reservedOwner(of: shortcut) { return .reserved(owner) }
            if let other = BrowserCommandID.allCases.first(where: { $0 != id && self.shortcut(for: $0) == shortcut }) {
                guard other.isRemappable else { return .refused(other) }
                guard swap else { return .conflict(other) }
                let previous = self.shortcut(for: id)
                setBinding(previous, for: other)
            }
        }
        setBinding(shortcut, for: id)
        return .assigned
    }

    mutating func setPriority(_ priority: BrowserShortcutPriority, for id: BrowserCommandID) {
        guard id.isRemappable else { return }
        settings[id].priority = priority
    }

    /// Back to the default shortcut and App wins. A command that took the
    /// default meanwhile keeps it; the reset one then has none.
    mutating func reset(_ id: BrowserCommandID) {
        settings[id] = .init()
        if let shortcut = id.defaultShortcut,
           BrowserCommandID.allCases.contains(where: { $0 != id && self.shortcut(for: $0) == shortcut })
        {
            settings[id].binding = BrowserShortcutSettings.Binding.none
        }
    }

    private mutating func setBinding(_ shortcut: BrowserShortcut?, for id: BrowserCommandID) {
        var entry = settings[id]
        if shortcut == id.defaultShortcut {
            entry.binding = nil
        } else if let shortcut {
            entry.binding = .shortcut(shortcut)
        } else {
            entry.binding = BrowserShortcutSettings.Binding.none
        }
        settings[id] = entry
    }
}

// MARK: - Priority gate

/// The site-wins and press-twice state of one window, pure, tracked per
/// forwarded key press (a token per event), so quick presses and key
/// repeat never share state. A shortcut pressed while a page has focus
/// asks `keyPressed`; with Site wins the key goes to the page and the app
/// runs the command when the page did not handle it: WebKit hands an
/// unhandled key back (`pageDidNotHandle`, authoritative whenever it
/// comes), or the page's `keydown` report says `defaultPrevented` was
/// false (`pageReported`), whichever comes first; the other answer for the
/// same press is swallowed. Press twice sends the first press to the page
/// and runs the command on a second identical press within
/// `pressTwiceInterval`; the first press's late hand-back is swallowed.
///
/// The report matches by `KeyboardEvent.code`, the physical key. On a
/// layout where a letter or punctuation sits elsewhere (QWERTZ Y/Z) the
/// report may not match; the hand-back still decides then, so only a page
/// that handled the key without `preventDefault` behaves differently.
struct BrowserShortcutGate: Sendable {
    static let pressTwiceInterval: TimeInterval = 1
    /// How long a report may match a forwarded key; hand-backs always do.
    static let answerTimeout: TimeInterval = 1
    /// Issued tokens remembered, so any hand-back of ours is recognized.
    static let rememberedTokens = 64

    enum Decision: Equatable, Sendable {
        /// Run the command; the page never sees this press.
        case run
        /// Let the page have the key.
        case forward
        /// Neither the app nor the page acts on it (again).
        case swallow
        /// Not the gate's: let the event continue as usual.
        case pass
    }

    struct Pending: Equatable, Sendable {
        var command: BrowserCommandID
        var shortcut: BrowserShortcut
        var priority: BrowserShortcutPriority
        var token: Int
        var at: Date
    }

    /// Forwarded presses still waiting for an answer, oldest first.
    private(set) var pending: [Pending] = []
    /// The last first press of a Press twice shortcut.
    private(set) var firstPress: (command: BrowserCommandID, at: Date, token: Int)?
    /// Every token handed out, newest last.
    private var issued: [Int] = []

    init() {}

    mutating func keyPressed(
        _ command: BrowserCommandID,
        shortcut: BrowserShortcut,
        priority: BrowserShortcutPriority,
        token: Int,
        at now: Date
    ) -> Decision {
        issued.append(token)
        if issued.count > Self.rememberedTokens { issued.removeFirst(issued.count - Self.rememberedTokens) }
        // A press the page answered without a hand-back never comes back.
        pending.removeAll { now.timeIntervalSince($0.at) > 10 }
        switch priority {
        case .app:
            firstPress = nil
            return .run
        case .site:
            pending.append(Pending(command: command, shortcut: shortcut, priority: .site, token: token, at: now))
            return .forward
        case .twice:
            if let first = firstPress, first.command == command,
               now.timeIntervalSince(first.at) <= Self.pressTwiceInterval
            {
                // The first press is answered: its late hand-back is
                // swallowed rather than run.
                firstPress = nil
                pending.removeAll { $0.token == first.token }
                return .run
            }
            firstPress = (command, now, token)
            pending.append(Pending(command: command, shortcut: shortcut, priority: .twice, token: token, at: now))
            return .forward
        }
    }

    /// WebKit handed forwarded key `token` back unhandled: a Site wins
    /// press still waiting runs (however late); anything else the gate
    /// issued is swallowed; an unknown token passes.
    mutating func pageDidNotHandle(token: Int, at now: Date) -> (Decision, BrowserCommandID?) {
        guard issued.contains(token) else { return (.pass, nil) }
        guard let index = pending.firstIndex(where: { $0.token == token }) else { return (.swallow, nil) }
        let press = pending.remove(at: index)
        return press.priority == .site ? (.run, press.command) : (.swallow, nil)
    }

    /// The page's `keydown` report for `shortcut`: whether a listener called
    /// `preventDefault`. Answers the oldest Site wins press of that shortcut
    /// still waiting: runs it when the page let it through.
    mutating func pageReported(_ shortcut: BrowserShortcut, prevented: Bool, at now: Date) -> BrowserCommandID? {
        guard let index = pending.firstIndex(where: {
            $0.priority == .site && $0.shortcut == shortcut && now.timeIntervalSince($0.at) <= Self.answerTimeout
        }) else { return nil }
        let press = pending.remove(at: index)
        return prevented ? nil : press.command
    }
}

// MARK: - Recent tabs

/// A window's tabs in the order they were last selected, newest first
/// (⌃Tab's switcher).
struct BrowserRecentTabs: Equatable, Sendable {
    static let switcherLimit = 5

    private(set) var order: [UUID] = []

    mutating func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// The most recent `limit` of `open` (closed tabs dropped; open tabs
    /// never selected follow in their given order).
    func recent(among open: [UUID], limit: Int = switcherLimit) -> [UUID] {
        let openSet = Set(open)
        var result = order.filter { openSet.contains($0) }
        let seen = Set(result)
        result += open.filter { !seen.contains($0) }
        return Array(result.prefix(limit))
    }
}

/// ⌃Tab's overlay while ⌃ is held: the recent tabs and the one Tab has
/// moved to. It opens on the previous tab; ⌃⇧Tab moves back.
struct BrowserRecentTabSwitcher: Equatable, Sendable {
    let items: [UUID]
    private(set) var index: Int

    init?(items: [UUID], forward: Bool) {
        guard items.count > 1 else { return nil }
        self.items = items
        index = forward ? 1 : items.count - 1
    }

    mutating func advance(forward: Bool) {
        index = (index + (forward ? 1 : -1) + items.count) % items.count
    }

    var selected: UUID { items[index] }
}

// MARK: - Rail walk

/// ⌥⌘↑/⌥⌘↓: the rail's items in order (favorites, the outline's shown
/// pins, the Today tabs) and the step from the selected one, wrapping.
enum BrowserRailWalk {
    enum Item: Equatable, Sendable {
        case favorite(UUID)
        case pin(UUID)
        case tab(UUID)
    }

    static func step(_ items: [Item], from current: Item?, by step: Int) -> Item? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(of: current) else {
            return step >= 0 ? items.first : items.last
        }
        return items[(index + step % items.count + items.count) % items.count]
    }
}
