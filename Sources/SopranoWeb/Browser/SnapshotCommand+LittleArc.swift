import AppKit

/// Little Arc flags for `SopranoWeb snapshot`, run in order with the
/// session actions, through the handlers File ▸ New Little Arc (⌥⌘N), the
/// toolbar's ⌘O button and its "Open in" menu call:
///
/// - `--little-arc <url|start>`: a Little Arc of the active window's Space
///   with `url` (a link from another app takes this path too), or ⌥⌘N's
///   start tab with the Command Bar (`start`). The new window becomes the
///   active one, so the capture shows it. Prints its window number and
///   Space.
/// - `--little-to-window`: ⌘O on the most recent Little Arc: its tab moves
///   into a window showing its Space (else the most recent normal window,
///   switched to it; else a new one). Prints where it landed.
/// - `--little-open-in <n|name>`: the most recent Little Arc's "Open in"
///   menu, Space n (1-based) or the Space named: a new Little Arc there
///   with the page, reloaded. Prints the menu's items and the result.
enum SnapshotLittleArcAction {
    case open(String)
    case toWindow
    case openIn(String)

    static let flags: Set<String> = ["--little-arc", "--little-to-window", "--little-open-in"]

    static let usage = """
                               [--little-arc <url|start>] [--little-to-window] [--little-open-in <n|name>]
    """

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotLittleArcAction? {
        switch option {
        case "--little-arc": return .open(try value())
        case "--little-to-window": return .toWindow
        case "--little-open-in": return .openIn(try value())
        default: return nil
        }
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        switch self {
        case let .open(value):
            let start = value == "start" || BrowserAddressResolver.isStartPage(URL(string: value))
            let little = manager.newLittleArc(url: start ? nil : value, commandBar: start)
            print("little-arc: window \(Self.number(little, in: manager)), Space \(Self.spaceName(little, in: manager))"
                + ", \(start ? "start page with the Command Bar" : value)")
        case .toWindow:
            guard let little = manager.mostRecentlyActive(where: { $0.role == .little }) else {
                print("little-to-window: no Little Arc is open")
                return
            }
            let title = little.selectedTab?.displayTitle ?? "?"
            guard let target = manager.moveLittleArcToSpaceWindow(little) else {
                print("little-to-window: nothing moved")
                return
            }
            let index = (target.visibleTabs.firstIndex { $0.id == target.selectedTab?.id } ?? 0) + 1
            print("little-to-window: \(title) -> window \(Self.number(target, in: manager)) (\(target.role.rawValue)), "
                + "Space \(Self.spaceName(target, in: manager)), tab \(index) of \(target.visibleTabs.count), "
                + "Little Arc \(manager.controllers.contains { $0 === little } ? "still open" : "closed")")
        case let .openIn(value):
            guard let little = manager.mostRecentlyActive(where: { $0.role == .little }) else {
                print("little-open-in: no Little Arc is open")
                return
            }
            let items = little.openInMenu().items.map { item in
                item.isSeparatorItem ? "—" : (item.state == .on ? "✓ " : "") + item.title
            }
            print("little-open-in: menu \(items.joined(separator: " | "))")
            guard case let .success(index) = BrowserAutomationRouter.resolveSpace(value, in: manager) else {
                print("little-open-in: no Space \(value)")
                return
            }
            let space = manager.spaces.spaces[index]
            guard let moved = manager.moveLittleArc(little, toSpace: space.id) else {
                print("little-open-in: already in \(space.displayName)")
                return
            }
            print("little-open-in: window \(Self.number(moved, in: manager)), Space \(Self.spaceName(moved, in: manager)), "
                + "\(moved.selectedTab?.state.url ?? "about:start") (reloads in its profile)")
        }
    }

    @MainActor
    private static func number(_ controller: BrowserWindowController, in manager: BrowserWindowManager) -> Int {
        (manager.controllers.firstIndex { $0 === controller } ?? -1) + 1
    }

    @MainActor
    private static func spaceName(_ controller: BrowserWindowController, in manager: BrowserWindowManager) -> String {
        manager.space(of: controller)?.displayName ?? "-"
    }
}
