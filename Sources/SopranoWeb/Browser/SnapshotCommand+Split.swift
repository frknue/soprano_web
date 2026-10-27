import AppKit
import WebKit

/// Split View flags for `SopranoWeb snapshot`, run in order with the session
/// actions on the active window, through the handlers the app uses (⌥-click
/// on a link opens a pane with `--click-page opt-X,Y`):
///
/// - `--split <url|start>` (repeatable): a new pane right of the focused
///   one (what `browser split [url]` runs). Prints the pane.
/// - `--split-command add|close|1…4`: the registry command (⌃⇧= opens the
///   pane with the Command Bar, ⌃⇧- closes the focused pane, ⌃⇧n focuses
///   pane n). Prints its title, whether it ran and the split after.
/// - `--split-focus <n>`: what `browser split focus n` runs.
/// - `--split-resize <divider>:<x>`: divider n (1-based, left to right)
///   dragged to `x` points of the page area, through the divider's drag
///   handler. Prints the ratios.
/// - `--split-drop <tab>:<x>|<window>:<tab>:<x>`: the page area's drop
///   handler for tab n of the active window (or of window w) dropped at
///   `x` points of the page (`left`/`right`: its edges). Prints the pane
///   index the edge math gave and the split after.
/// - `--split-separate`: the split row's Separate Split View.
/// - `--print-splits`: one JSON line per window: its splits (panes with
///   tab numbers, titles, origins, ratios, the focused pane, the pane and
///   divider frames on screen), the rail's Today rows and the strip's
///   items as their views show them, and `tabs`' CLI lines.
enum SnapshotSplitAction {
    case add(String)
    case command(String)
    case focus(Int)
    case resize(divider: Int, x: Double)
    case drop(window: Int?, tab: Int, x: String)
    case separate
    case print

    static let flags: Set<String> = [
        "--split", "--split-command", "--split-focus", "--split-resize", "--split-drop", "--split-separate",
        "--print-splits",
    ]

    static let usage = """
                               [--split <url|start>]... [--split-command add|close|1|2|3|4] [--split-focus <n>]
                               [--split-resize <divider>:<x>] [--split-drop [<window>:]<tab>:<x|left|right>]
                               [--split-separate] [--print-splits]
    """

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotSplitAction? {
        switch option {
        case "--split": return .add(try value())
        case "--split-command":
            let name = try value()
            guard ["add", "close", "1", "2", "3", "4"].contains(name) else {
                throw SnapshotCommand.OptionError.unknownOption("--split-command \(name)")
            }
            return .command(name)
        case "--split-focus":
            let text = try value()
            guard let number = Int(text), number > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--split-focus \(text)")
            }
            return .focus(number)
        case "--split-resize":
            let text = try value()
            let parts = text.split(separator: ":")
            guard parts.count == 2, let divider = Int(parts[0]), divider > 0, let x = Double(parts[1]) else {
                throw SnapshotCommand.OptionError.unknownOption("--split-resize \(text)")
            }
            return .resize(divider: divider, x: x)
        case "--split-drop":
            let text = try value()
            let parts = text.split(separator: ":").map(String.init)
            switch parts.count {
            case 2:
                guard let tab = Int(parts[0]) else { throw SnapshotCommand.OptionError.unknownOption("--split-drop \(text)") }
                return .drop(window: nil, tab: tab, x: parts[1])
            case 3:
                guard let window = Int(parts[0]), let tab = Int(parts[1]) else {
                    throw SnapshotCommand.OptionError.unknownOption("--split-drop \(text)")
                }
                return .drop(window: window, tab: tab, x: parts[2])
            default:
                throw SnapshotCommand.OptionError.unknownOption("--split-drop \(text)")
            }
        case "--split-separate": return .separate
        case "--print-splits": return .print
        default: return nil
        }
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        guard let controller = manager.activeController else {
            Swift.print("snapshot: no window is open")
            return
        }
        switch self {
        case let .add(value):
            let arguments = value == "start" ? [] : [value]
            switch controller.performSplitCommand(arguments) {
            case .success(let output): Swift.print("split: \(output)")
            case .failure(let error): Swift.print("split error: \(error.localizedDescription)")
            }
            Self.settle()
        case let .command(name):
            let id: BrowserCommandID = switch name {
            case "add": .splitAdd
            case "close": .splitClose
            case "1": .splitPane1
            case "2": .splitPane2
            case "3": .splitPane3
            default: .splitPane4
            }
            let context = BrowserCommandContext(manager: manager, controller: controller)
            let command = id.command
            let state = command.state(context)
            if state.isEnabled {
                command.perform(in: context)
            }
            Swift.print("split-command: \(command.title) (\(command.shortcut?.display ?? "-")) "
                + "\(state.isEnabled ? "ran" : "disabled"), \(Self.summary(controller)), "
                + "Command Bar \(controller.commandBar.isOpen ? "open" : "closed")")
            Self.settle()
        case let .focus(number):
            switch controller.performSplitCommand(["focus", String(number)]) {
            case .success(let output): Swift.print("split-focus: \(output)")
            case .failure(let error): Swift.print("split-focus error: \(error.localizedDescription)")
            }
        case let .resize(divider, x):
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            guard let view = controller.splitPage.dividers.first(where: { $0.index == divider - 1 }) else {
                Swift.print("split-resize: no divider \(divider)")
                return
            }
            view.onDrag?(view.index, CGFloat(x))
            view.onDragEnded?()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            Swift.print("split-resize: divider \(divider) to x \(Int(x)) -> \(Self.summary(controller))")
        case let .drop(windowNumber, tabNumber, xText):
            let windows = manager.controllers
            let source: BrowserWindowController? = if let windowNumber {
                windows.indices.contains(windowNumber - 1) ? windows[windowNumber - 1] : nil
            } else {
                controller
            }
            guard let source, source.visibleTabs.indices.contains(tabNumber - 1) else {
                Swift.print("split-drop: no tab \(tabNumber)")
                return
            }
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let tab = source.visibleTabs[tabNumber - 1]
            let width = Double(controller.webArea.bounds.width)
            let x: Double = switch xText {
            case "left": 8
            case "right": width - 8
            default: Double(xText) ?? width / 2
            }
            // What the page area's drag handlers call.
            let area = controller.webArea
            let insertion = area.dropTarget?(tab.id, CGFloat(x))
            let dropped = insertion.map { area.onDropTab?(tab.id, $0) ?? false } ?? false
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            Swift.print("split-drop: \"\(tab.displayTitle)\" at x \(Int(x)) of \(Int(width)) -> "
                + "\(insertion.map { "pane \($0 + 1)" } ?? "refused") \(dropped ? "dropped" : "not dropped"), "
                + Self.summary(controller))
        case .separate:
            guard let split = controller.shownSplit else {
                Swift.print("split-separate: no split on screen")
                return
            }
            controller.separateSplit(id: split.id)
            Swift.print("split-separate: \(Self.summary(controller))")
        case .print:
            for window in manager.controllers {
                Swift.print(Self.json(window, number: (manager.controllers.firstIndex { $0 === window } ?? 0) + 1))
            }
        }
    }

    /// Lets the page area lay out and loads start.
    @MainActor
    private static func settle() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    /// `split on screen: k panes [titles] ratios [..] focused p`, or none.
    @MainActor
    private static func summary(_ controller: BrowserWindowController) -> String {
        guard let split = controller.shownSplit else {
            return "no split on screen, selected \"\(controller.selectedTab?.displayTitle ?? "-")\", \(controller.splits.count) split(s)"
        }
        let titles = split.tabIDs.compactMap { id in controller.tabs.first { $0.id == id }?.displayTitle }
        let ratios = split.ratios.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let focused = (split.index(of: split.focusedTabID) ?? 0) + 1
        return "split on screen: \(titles.count) panes [\(titles.joined(separator: " | "))] ratios [\(ratios)] focused \(focused)"
    }

    @MainActor
    private static func origin(_ tab: BrowserTab) -> String {
        switch tab.origin {
        case .today: "today"
        case .pinned: "pinned"
        case .favorite: "favorite"
        }
    }

    @MainActor
    private static func json(_ controller: BrowserWindowController, number: Int) -> String {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let shown = controller.shownSplit?.id
        let splits: [[String: Any]] = controller.visibleSplits.map { split in
            let panes: [[String: Any]] = split.tabIDs.compactMap { id in
                guard let tab = controller.tabs.first(where: { $0.id == id }) else { return nil }
                var pane: [String: Any] = [
                    "tab": (controller.visibleTabs.firstIndex { $0 === tab } ?? -1) + 1,
                    "title": tab.displayTitle,
                    "url": tab.webView.url?.absoluteString ?? tab.state.url ?? "about:start",
                    "origin": origin(tab),
                    "focused": id == split.focusedTabID,
                    "hidden": tab.webView.isHidden,
                    "sleepExemption": controller.sleepExemption(tab)?.rawValue ?? NSNull(),
                ]
                if split.id == shown {
                    let frame = tab.webView.frame
                    pane["frame"] = [Int(frame.minX), Int(frame.width)]
                }
                return pane
            }
            var object: [String: Any] = [
                "panes": panes,
                "ratios": split.ratios.map { ($0 * 1000).rounded() / 1000 },
                "onScreen": split.id == shown,
            ]
            if split.id == shown {
                object["dividers"] = controller.splitPage.dividers.map { [Int($0.frame.minX), Int($0.frame.width)] }
                object["focusRing"] = !controller.splitPage.focusRing.isHidden
            }
            return object
        }
        let rowTitle: (BrowserTabRow) -> String = { row in
            guard let item = controller.rowItem(row) else { return "?" }
            switch row {
            case .tab: return item.title
            case .split: return "[split " + item.panes.map(\.title).joined(separator: " | ") + "]"
            }
        }
        let object: [String: Any] = [
            "window": number,
            "pageWidth": Int(controller.webArea.bounds.width),
            "selected": controller.selectedTab?.displayTitle ?? NSNull(),
            "selectedRow": controller.selectedRowID.map { id in controller.split(id: id) != nil ? "split" : "tab" } ?? NSNull(),
            "splits": splits,
            "railRows": controller.todayRows.map(rowTitle),
            "stripItems": controller.stripRows.map(rowTitle),
            "tabs": controller.automationTabLines(),
            "session": controller.windowState.splits.map { ["tabs": $0.tabs, "focused": $0.focused] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return "splits: " + text
    }
}
