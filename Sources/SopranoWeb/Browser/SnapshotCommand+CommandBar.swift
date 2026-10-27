import AppKit
import WebKit

/// Command Bar and shortcut flags for `SopranoWeb snapshot`, run in order
/// with the session actions on the active window, through the handlers a
/// key press or click calls:
///
/// - `--command-bar [text]`: ⌘T, then types `text` (a value is any next
///   argument that isn't a flag). `--command-bar-location` is ⌘L (the
///   selected tab's address), `--command-bar-actions` ⇧⌘P (`/`), and
///   `--command-bar-type <text>` types into the open bar.
/// - `--command-bar-key <key>` (repeatable): the field editor's command for
///   `down`, `up`, `tab`, `enter`, `esc`, `backspace`, `ctrl-n`, `ctrl-p`.
///   `enter` prints the chosen row and the selected tab after it.
/// - `--print-command-bar`: one `command-bar:` JSON line (open, mode, text,
///   site-search chip, selection, groups and rows with their targets).
/// - `--set-shortcut <command id>=<shortcut>[:app|site|twice]`: recorded in
///   Settings ▸ Keyboard shortcuts (`shift+cmd+u` or `⇧⌘U`; `none`
///   removes it); prints the answer and `settings.json`'s `shortcuts`. A
///   conflict stays open in the sheet; `--shortcut-swap` and
///   `--shortcut-cancel` press its buttons. `--shortcuts-sheet` captures
///   the sheet.
/// - `--page-key <shortcut>[ x2]`: a key-down sent to the selected tab's
///   focused page the way AppKit sends a key equivalent (the window's
///   views first), twice 0.3 s apart with ` x2`; prints the command it is,
///   its priority, the page's `window.__keyLog` and the pasteboard.
/// - `--recent-tabs <n>`: ⌃Tab pressed n times, then ⌃ released (prints
///   the order and the selected tab); `--recent-tabs-hold <n>` keeps ⌃
///   held so the capture shows the overlay.
/// - `--walk-rail down|up`: ⌥⌘↓ / ⌥⌘↑.
/// - `--toggle-toolbar`: ⇧⌘D.
/// - `--copy-url` / `--copy-markdown`: ⇧⌘C / ⌥⇧⌘C, printing the
///   pasteboard. The harness copies to a private named pasteboard, never
///   the general one.
enum SnapshotCommandBarAction {
    case open(BrowserCommandBarMode, text: String?)
    case type(String)
    case key(String)
    case print
    case setShortcut(BrowserCommandID, String, BrowserShortcutPriority?)
    case resolveConflict(swap: Bool)
    case pageKey(BrowserShortcut, times: Int)
    case recentTabs(Int, commit: Bool)
    case walkRail(Int)
    case toggleToolbar
    case copy(markdown: Bool)

    static let flags: Set<String> = [
        "--command-bar", "--command-bar-location", "--command-bar-actions", "--command-bar-type",
        "--command-bar-key", "--print-command-bar", "--set-shortcut", "--shortcut-swap", "--shortcut-cancel",
        "--page-key", "--recent-tabs", "--recent-tabs-hold", "--walk-rail", "--toggle-toolbar", "--copy-url",
        "--copy-markdown",
    ]

    static let usage = """
                               [--command-bar [text]] [--command-bar-location] [--command-bar-actions]
                               [--command-bar-type <text>] [--command-bar-key down|up|tab|enter|esc|backspace]...
                               [--print-command-bar] [--set-shortcut <id>=<shortcut>[:app|site|twice]]...
                               [--shortcut-swap] [--shortcut-cancel] [--shortcuts-sheet]
                               [--page-key "<shortcut>[ x2]"]... [--recent-tabs <n>] [--recent-tabs-hold <n>]
                               [--walk-rail down|up] [--toggle-toolbar] [--copy-url] [--copy-markdown]
    """

    /// The keys `--command-bar-key` names and the field editor command each
    /// sends (⌃N and ⌃P are moveDown: and moveUp: in the standard key
    /// bindings).
    static let keys: [String: Selector] = [
        "down": #selector(NSResponder.moveDown(_:)),
        "ctrl-n": #selector(NSResponder.moveDown(_:)),
        "up": #selector(NSResponder.moveUp(_:)),
        "ctrl-p": #selector(NSResponder.moveUp(_:)),
        "tab": #selector(NSResponder.insertTab(_:)),
        "enter": #selector(NSResponder.insertNewline(_:)),
        "esc": #selector(NSResponder.cancelOperation(_:)),
        "backspace": #selector(NSResponder.deleteBackward(_:)),
    ]

    /// Nil when `option` is not one of these flags. `peek` is the next
    /// argument (for `--command-bar`'s optional text) and `skip` consumes it.
    static func parse(
        _ option: String,
        value: () throws -> String,
        peek: () -> String?,
        skip: () -> Void
    ) throws -> SnapshotCommandBarAction? {
        func bad(_ raw: String) -> SnapshotCommand.OptionError { .unknownOption("\(option) \(raw)") }
        switch option {
        case "--command-bar":
            if let next = peek(), !next.hasPrefix("--") {
                skip()
                return .open(.newTab, text: next)
            }
            return .open(.newTab, text: nil)
        case "--command-bar-location": return .open(.editCurrent, text: nil)
        case "--command-bar-actions": return .open(.actions, text: nil)
        case "--command-bar-type": return .type(try value())
        case "--command-bar-key":
            let raw = try value()
            guard keys[raw] != nil else { throw bad(raw) }
            return .key(raw)
        case "--print-command-bar": return .print
        case "--set-shortcut":
            let raw = try value()
            guard let equals = raw.firstIndex(of: "="),
                  let id = BrowserCommandID(rawValue: String(raw[..<equals]))
            else { throw bad(raw) }
            var shortcut = String(raw[raw.index(after: equals)...])
            var priority: BrowserShortcutPriority?
            if let colon = shortcut.lastIndex(of: ":"),
               let parsed = BrowserShortcutPriority(rawValue: String(shortcut[shortcut.index(after: colon)...]))
            {
                priority = parsed
                shortcut = String(shortcut[..<colon])
            }
            return .setShortcut(id, shortcut, priority)
        case "--shortcut-swap": return .resolveConflict(swap: true)
        case "--shortcut-cancel": return .resolveConflict(swap: false)
        case "--page-key":
            let raw = try value()
            let twice = raw.hasSuffix(" x2")
            guard let shortcut = BrowserShortcut(twice ? String(raw.dropLast(3)) : raw) else { throw bad(raw) }
            return .pageKey(shortcut, times: twice ? 2 : 1)
        case "--recent-tabs", "--recent-tabs-hold":
            let raw = try value()
            guard let presses = Int(raw), presses > 0 else { throw bad(raw) }
            return .recentTabs(presses, commit: option == "--recent-tabs")
        case "--walk-rail":
            let raw = try value()
            guard raw == "down" || raw == "up" else { throw bad(raw) }
            return .walkRail(raw == "down" ? 1 : -1)
        case "--toggle-toolbar": return .toggleToolbar
        case "--copy-url": return .copy(markdown: false)
        case "--copy-markdown": return .copy(markdown: true)
        default: return nil
        }
    }

    /// Settings ▸ Keyboard shortcuts, built offscreen on first use (and for
    /// `--shortcuts-sheet`).
    @MainActor static var shortcutsSheet: BrowserShortcutsSheet?

    @MainActor
    static func sheet(for manager: BrowserWindowManager) -> BrowserShortcutsSheet {
        if let shortcutsSheet { return shortcutsSheet }
        let sheet = BrowserShortcutsSheet(settingsStore: manager.settingsStore, theme: manager.themeManager.currentTheme)
        shortcutsSheet = sheet
        return sheet
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        guard let controller = manager.activeController else {
            Swift.print("snapshot: no window is open")
            return
        }
        let bar = controller.commandBar
        switch self {
        case let .open(mode, text):
            controller.showCommandBar(mode)
            if let text {
                bar.type(text)
            }
            Swift.print("command-bar: opened \(mode.rawValue) with “\(bar.text)” (\(bar.rows.count) rows)")
        case let .type(text):
            bar.type(text)
        case let .key(name):
            let rows = bar.rows
            let selection = bar.selection
            _ = bar.handle(Self.keys[name]!)
            if name == "enter" {
                let chosen = rows.indices.contains(selection) ? rows[selection] : nil
                let target = manager.activeController ?? controller
                let space = target.currentSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? "-"
                Swift.print("command-bar: enter on \(chosen.map { "\($0.kind.rawValue) “\($0.title)” \(BrowserCommandBarController.describe($0.target))" } ?? "nothing") | open \(bar.isOpen) | Space \(space) | tabs \(target.visibleTabs.count) | selected \(target.selectedTab.map(SnapshotRailAction.describe) ?? "-")")
            } else {
                Swift.print("command-bar: \(name) -> selection \(bar.selection), chip \(bar.siteSearch?.name ?? "none"), text “\(bar.text)”, open \(bar.isOpen)")
            }
        case .print:
            let object = bar.dump()
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            Swift.print("command-bar: " + String(decoding: data, as: UTF8.self))
        case let .setShortcut(id, text, priority):
            let sheet = Self.sheet(for: manager)
            if text.lowercased() == "none" {
                manager.settingsStore.update { $0.keymap.assign(nil, to: id) }
                Swift.print("set-shortcut: \(id.rawValue) -> none")
            } else if let shortcut = BrowserShortcut(text) {
                let result = sheet.record(shortcut, for: id)
                Swift.print("set-shortcut: \(id.rawValue) \(shortcut.display) -> \(Self.describe(result))")
            } else {
                Swift.print("set-shortcut: can't read \(text)")
            }
            if let priority {
                sheet.setPriority(priority, for: id)
            }
            Swift.print("set-shortcut: \(id.rawValue) is \(manager.settingsStore.settings.keymap.shortcut(for: id)?.display ?? "none") (\(manager.settingsStore.settings.keymap.priority(for: id).title))")
            Swift.print("settings.json shortcuts: \(Self.savedShortcuts(manager))")
        case let .resolveConflict(swap):
            let sheet = Self.sheet(for: manager)
            let conflict = sheet.conflict.map(BrowserShortcutsSheet.message) ?? "none"
            sheet.resolveConflict(swap: swap)
            Swift.print("shortcut-conflict: \(conflict) -> \(swap ? "Swap" : "Cancel")")
            Swift.print("settings.json shortcuts: \(Self.savedShortcuts(manager))")
        case let .pageKey(shortcut, times):
            Self.sendPageKeys(shortcut, times: times, to: controller, manager: manager)
        case let .recentTabs(presses, commit):
            let titles = { (ids: [UUID]) in
                ids.compactMap { id in controller.tabs.first { $0.id == id }?.displayTitle }
            }
            Swift.print("recent-tabs: MRU \(titles(controller.recentTabs.recent(among: controller.tabs.map(\.id))))")
            for _ in 0..<presses {
                controller.showRecentTabs(forward: true, commitWhenReleased: false)
            }
            Swift.print("recent-tabs: \(presses) × ⌃Tab -> \(controller.recentTabsOverlay?.dump ?? [])")
            if commit {
                controller.commitRecentTabs()
                let target = manager.activeController ?? controller
                Swift.print("recent-tabs: released ⌃ -> selected \(target.selectedTab.map(SnapshotRailAction.describe) ?? "-")")
            }
        case let .walkRail(step):
            controller.walkRail(step: step)
            let target = manager.activeController ?? controller
            Swift.print("walk-rail: \(step > 0 ? "⌥⌘↓" : "⌥⌘↑") -> \(target.selectedTab.map(SnapshotRailAction.describe) ?? "-")")
        case .toggleToolbar:
            controller.toggleToolbar()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            Swift.print("toggle-toolbar: toolbar \(controller.isToolbarHidden ? "hidden" : "shown") (toolbar view hidden \(controller.toolbar.isHidden), defaults \(manager.defaults.bool(forKey: BrowserWindowController.toolbarHiddenKey)))")
        case let .copy(markdown):
            manager.pasteboard.clearContents()
            controller.copyPageAddress(markdown: markdown)
            Swift.print("\(markdown ? "copy-markdown" : "copy-url"): \(manager.pasteboard.string(forType: .string) ?? "(empty)")")
        }
    }

    private static func describe(_ result: BrowserKeymap.Assignment) -> String {
        switch result {
        case .assigned: "assigned"
        case let .conflict(other): "conflict with \(other.rawValue) (\(other.command.title))"
        case let .refused(other): "refused: \(other.command.title) can't change"
        case let .reserved(owner): "refused: reserved by \(owner)"
        case .invalid: "invalid (needs ⌘ or ⌃)"
        }
    }

    @MainActor
    private static func savedShortcuts(_ manager: BrowserWindowManager) -> String {
        guard let data = try? Data(contentsOf: manager.settingsStore.url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shortcuts = object["shortcuts"],
              let json = try? JSONSerialization.data(withJSONObject: shortcuts, options: [.sortedKeys])
        else { return "(none)" }
        return String(decoding: json, as: UTF8.self)
    }

    /// Key-downs into the selected tab's page as AppKit delivers a key
    /// equivalent: the page's web view becomes first responder, the window
    /// gets `performKeyEquivalent` and, unhandled, the web view `keyDown`.
    /// With `times` 2 the second press follows 0.05 s later, before the page
    /// answers the first (key repeat, a quick double press). Then waits for
    /// the answers and prints once.
    @MainActor
    private static func sendPageKeys(
        _ shortcut: BrowserShortcut,
        times: Int,
        to controller: BrowserWindowController,
        manager: BrowserWindowManager
    ) {
        guard let window = controller.window else { return }
        manager.pasteboard.clearContents()
        let keymap = manager.settingsStore.settings.keymap
        let command = keymap.command(for: shortcut)
        let tabsBefore = controller.tabs.count
        for press in 1...times {
            if press > 1 { spin(0.05) }
            guard let tab = controller.selectedTab, let event = keyEvent(shortcut, window: window) else {
                Swift.print("page-key: can't send \(shortcut.display)")
                return
            }
            window.makeFirstResponder(tab.webView)
            if !window.performKeyEquivalent(with: event) {
                tab.webView.keyDown(with: event)
            }
        }
        spin(0.4)
        var log = ""
        var finished = false
        controller.selectedTab?.webView.evaluateJavaScript("(window.__keyLog || []).join(',')") { result, _ in
            log = result as? String ?? ""
            finished = true
        }
        spin(2) { finished }
        let priority = command.map { keymap.priority(for: $0).title } ?? "-"
        let presses = times == 1 ? "" : " ×\(times)"
        Swift.print("page-key: \(shortcut.display)\(presses) -> \(command?.rawValue ?? "no command") (\(priority)) | tabs \(tabsBefore) -> \(controller.tabs.count) | page log [\(log)] | pasteboard: \(manager.pasteboard.string(forType: .string) ?? "(empty)")")
    }

    /// A key-down NSEvent for `shortcut` with the US layout's key code (so
    /// the page's `KeyboardEvent.code` is right).
    @MainActor
    private static func keyEvent(_ shortcut: BrowserShortcut, window: NSWindow) -> NSEvent? {
        guard let code = keyCodes[shortcut.key] else { return nil }
        let base = shortcut.keyEquivalent
        let characters = shortcut.modifiers.contains(.shift) && base.count == 1 && base.first!.isLetter
            ? base.uppercased()
            : base
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifierMask,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, "tab": 48, "return": 36, "delete": 51, "escape": 53, "space": 49, "left": 123,
        "right": 124, "down": 125, "up": 126,
    ]

    @MainActor
    private static func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }
}
