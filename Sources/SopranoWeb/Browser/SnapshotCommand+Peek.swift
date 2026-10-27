import AppKit
import WebKit

/// Peek flags for `SopranoWeb snapshot`, run in order with the session
/// actions on the active window, through the handlers the app uses (a link
/// click opens one with `--click-page shift-X,Y`, or from a pinned or
/// favorite tab to another site with a plain click):
///
/// - `--peek <url>`: a Peek of `url` over the selected tab (what
///   `browser peek <url>` runs). Prints the tab it is over.
/// - `--peek-open-as-tab`: ⌘O ("Open as Tab", the registry command): the
///   Peek's page becomes a Today tab after its opener. Prints its place,
///   address and back list.
/// - `--peek-close esc|cmd-w|backdrop|button`: closes the Peek the way
///   named: an Esc key event through the Peek page's key handling, the
///   ⌘W registry command, a click on the dimmed page, the close button.
/// - `--print-peek`: one JSON line: the open Peek (address, title and host
///   its title bar shows, back and forward lists, the opener tab, data
///   Space, private, the panel's frame in the window, the open button,
///   whether the Peek has the focus, its profile's newest History
///   visits) and the window's tabs, or `{"open":false}`.
enum SnapshotPeekAction {
    case open(String)
    case openAsTab
    case close(String)
    case print

    static let flags: Set<String> = ["--peek", "--peek-open-as-tab", "--peek-close", "--print-peek"]

    static let usage = """
                               [--peek <url>] [--peek-open-as-tab] [--peek-close esc|cmd-w|backdrop|button] [--print-peek]
    """

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotPeekAction? {
        switch option {
        case "--peek": return .open(try value())
        case "--peek-open-as-tab": return .openAsTab
        case "--peek-close":
            let way = try value()
            guard ["esc", "cmd-w", "backdrop", "button"].contains(way) else {
                throw SnapshotCommand.OptionError.unknownOption("--peek-close \(way)")
            }
            return .close(way)
        case "--print-peek": return .print
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
        case let .open(value):
            let request = BrowserCommandRequest(command: "peek", arguments: [value], tabIndex: nil)
            switch BrowserAutomationRouter.peek(request, in: controller) {
            case .success(let output): Swift.print("peek: \(output)")
            case .failure(let error): Swift.print("peek error: \(error.localizedDescription)")
            }
        case .openAsTab:
            guard controller.peek != nil else {
                Swift.print("peek-open-as-tab: no Peek is open")
                return
            }
            let context = BrowserCommandContext(manager: manager, controller: controller)
            let title = BrowserCommandID.openInSpaceWindow.command.state(context).title ?? "?"
            BrowserCommandID.openInSpaceWindow.command.perform(in: context)
            guard let tab = controller.selectedTab else { return }
            let index = (controller.visibleTabs.firstIndex { $0 === tab } ?? 0) + 1
            let back = tab.webView.backForwardList.backList.map(\.url.absoluteString)
            Swift.print("peek-open-as-tab: \(title) -> tab \(index) of \(controller.visibleTabs.count) (\(Self.origin(tab))), "
                + "\(tab.webView.url?.absoluteString ?? "") back [\(back.joined(separator: ", "))], "
                + "Peek \(controller.peek == nil ? "closed" : "still open")")
        case let .close(way):
            guard let peek = controller.peek else {
                Swift.print("peek-close: no Peek is open")
                return
            }
            switch way {
            case "esc":
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
                )
                if let event { peek.tab.webView.keyDown(with: event) }
            case "cmd-w":
                let context = BrowserCommandContext(manager: manager, controller: controller)
                Swift.print("peek-close: ⌘W is \"\(BrowserCommandID.closeTab.command.state(context).title ?? "Close Tab")\"")
                BrowserCommandID.closeTab.command.perform(in: context)
            case "backdrop":
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                )
                if let event { peek.view.backdrop.mouseDown(with: event) }
            default:
                peek.view.closeButton.performClick(nil)
            }
            Swift.print("peek-close: \(way) -> Peek \(controller.peek == nil ? "closed" : "still open"), "
                + "\(controller.visibleTabs.count) tabs, selected \(controller.selectedTab?.displayTitle ?? "-")")
        case .print:
            Swift.print(Self.json(controller, manager: manager))
        }
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
    private static func json(_ controller: BrowserWindowController, manager: BrowserWindowManager) -> String {
        let tabs: [[String: Any]] = controller.visibleTabs.map { tab in
            [
                "title": tab.displayTitle,
                "url": tab.webView.url?.absoluteString ?? tab.state.url ?? "about:start",
                "origin": origin(tab),
                "selected": tab.id == controller.selectedTab?.id,
            ]
        }
        var object: [String: Any] = ["open": controller.peek != nil, "tabs": tabs]
        if let peek = controller.peek {
            let tab = peek.tab
            let view = peek.view
            let list = tab.webView.backForwardList
            let opener = controller.visibleTabs.firstIndex { $0.id == peek.openerID }
            let panel = view.panel.convert(view.panel.bounds, to: nil)
            let context = tab.dataContext
            let responder = controller.window?.firstResponder as? NSView
            object["url"] = tab.webView.url?.absoluteString ?? tab.pendingURL ?? NSNull()
            object["title"] = view.titleLabel.stringValue
            object["host"] = view.hostLabel.stringValue
            object["back"] = list.backList.map(\.url.absoluteString)
            object["forward"] = list.forwardList.map(\.url.absoluteString)
            object["canGoBack"] = view.backButton.isEnabled
            object["canGoForward"] = view.forwardButton.isEnabled
            object["openButton"] = "\(view.openButton.title) \(view.openButton.keycap ?? "")"
            object["opener"] = opener.map { index -> [String: Any] in
                let tab = controller.visibleTabs[index]
                return ["tab": index + 1, "title": tab.displayTitle, "origin": origin(tab)]
            } ?? NSNull()
            object["dataSpace"] = manager.spaces.space(ofProfile: context.profileID)?.displayName ?? NSNull()
            object["sameContextAsOpener"] = controller.tabs.first { $0.id == peek.openerID }?.dataContext === context
            object["private"] = context.kind.isPrivate
            object["panel"] = [
                "x": Int(panel.minX), "y": Int(panel.minY), "width": Int(panel.width), "height": Int(panel.height),
            ]
            object["pageArea"] = [
                "width": Int(controller.webArea.bounds.width), "height": Int(controller.webArea.bounds.height),
            ]
            object["focused"] = responder.map { $0.isDescendant(of: view) } ?? false
            object["inTabList"] = controller.tabs.contains { $0 === tab }
            object["historyURLs"] = context.kind.recordsHistory
                ? context.history.visits(limit: 10).map(\.url)
                : []
            object["recordsHistory"] = context.kind.recordsHistory
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "peek: " + (String(data: data, encoding: .utf8) ?? "{}")
    }
}
