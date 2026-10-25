import AppKit
import WebKit

/// Session and window flags for `SopranoWeb snapshot`. Actions run in the
/// order given, after the initial `--url` load, each followed by `--wait`,
/// on the active window (the most recently opened or activated one):
///
/// - `--session <file>`: restore this session file (version 1 or 2) at
///   launch (a copy; never written back). Every saved window opens.
/// - `--visit <url>`: navigate the selected tab.
/// - `--select <n>`: select tab n (1-based).
/// - `--close-tab`, `--reopen-closed` (⇧⌘T), `--duplicate`, `--go-back`,
///   `--reload` (⌘R).
/// - `--close-window`: ⇧⌘W on the active window.
/// - `--new-window <url>`: File ▸ New Window, then load `url` (`start` for
///   the start page). The window stays off every display.
/// - `--activate-window <n>`: make window n the active one.
/// - `--move-tab <w>:<t>:<w2>`: detach tab t of window w and attach it to
///   window w2 (selected), the path moving a live tab takes.
/// - `--start-download <url>`: start a download in the active window and
///   go on without waiting for it; `--wait-downloads` waits for every
///   download to stop.
/// - `--crash`: kill the selected tab's web content process.
/// - `--crash-page`: show the crash page on the selected tab.
/// - `--print-windows`: print every window, its frame and tabs, the
///   recently-closed stack and the downloads as one JSON line.
/// - `--dump-tabs`: print the active window's tabs as one JSON line after
///   the actions.
/// - `--save-session <file>`: write the session after the actions.
/// - `--capture-window <n>`: capture window n instead of the active one.
struct SnapshotSessionOptions {
    enum Action {
        case visit(String)
        case select(Int)
        case closeTab
        case reopenClosed
        case duplicate
        case goBack
        case reload
        case closeWindow
        case newWindow(String)
        case activateWindow(Int)
        case moveTab(from: Int, tab: Int, to: Int)
        case startDownload(String)
        case waitDownloads
        case crash
        case crashPage
        case printWindows
    }

    static let flags: Set<String> = [
        "--session", "--visit", "--select", "--close-tab", "--reopen-closed", "--duplicate",
        "--go-back", "--reload", "--close-window", "--new-window", "--activate-window", "--move-tab",
        "--start-download", "--wait-downloads", "--crash", "--crash-page", "--print-windows",
        "--dump-tabs", "--save-session", "--capture-window",
    ]
    static let usage = """
                               [--session <file>] [--visit <url>] [--select <n>] [--close-tab]
                               [--reopen-closed] [--duplicate] [--go-back] [--reload]
                               [--close-window] [--new-window <url>]... [--activate-window <n>]
                               [--move-tab <window>:<tab>:<window>] [--start-download <url>]
                               [--wait-downloads] [--crash] [--crash-page] [--print-windows]
                               [--dump-tabs] [--save-session <file>] [--capture-window <n>]
    """

    var restoreFrom: URL?
    var actions: [Action] = []
    var dumpTabs = false
    var saveTo: URL?
    var captureWindow: Int?

    var restoresSession: Bool { restoreFrom != nil }

    /// The sidebar's sample downloads would blur a real one.
    var startsDownloads: Bool {
        actions.contains { if case .startDownload = $0 { true } else { false } }
    }

    mutating func parse(_ option: String, value: () throws -> String) throws {
        func number() throws -> Int {
            let raw = try value()
            guard let number = Int(raw), number > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("\(option) \(raw)")
            }
            return number
        }
        switch option {
        case "--session": restoreFrom = URL(fileURLWithPath: try value())
        case "--visit": actions.append(.visit(try value()))
        case "--select": actions.append(.select(try number()))
        case "--close-tab": actions.append(.closeTab)
        case "--reopen-closed": actions.append(.reopenClosed)
        case "--duplicate": actions.append(.duplicate)
        case "--go-back": actions.append(.goBack)
        case "--reload": actions.append(.reload)
        case "--close-window": actions.append(.closeWindow)
        case "--new-window": actions.append(.newWindow(try value()))
        case "--activate-window": actions.append(.activateWindow(try number()))
        case "--move-tab":
            let raw = try value()
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 > 0 }) else {
                throw SnapshotCommand.OptionError.unknownOption("--move-tab \(raw)")
            }
            actions.append(.moveTab(from: parts[0], tab: parts[1], to: parts[2]))
        case "--start-download": actions.append(.startDownload(try value()))
        case "--wait-downloads": actions.append(.waitDownloads)
        case "--crash": actions.append(.crash)
        case "--crash-page": actions.append(.crashPage)
        case "--print-windows": actions.append(.printWindows)
        case "--dump-tabs": dumpTabs = true
        case "--save-session": saveTo = URL(fileURLWithPath: try value())
        case "--capture-window": captureWindow = try number()
        default: throw SnapshotCommand.OptionError.unknownOption(option)
        }
    }

    /// Copies the session file to where the harness's volatile store reads it.
    func prepare(sessionURL: URL) {
        guard let restoreFrom else { return }
        try? FileManager.default.copyItem(at: restoreFrom, to: sessionURL)
    }

    @MainActor
    func run(_ manager: BrowserWindowManager, wait seconds: Double) {
        for action in actions {
            autoreleasepool { perform(action, in: manager) }
            Self.spin(seconds)
        }
        if dumpTabs, let controller = manager.activeController {
            print(Self.dump(controller))
        }
        if let saveTo {
            try? JSONFile.write(manager.currentSession, to: saveTo)
        }
    }

    /// `--capture-window n`, else the active window.
    @MainActor
    func captureController(in manager: BrowserWindowManager) -> BrowserWindowController? {
        guard let captureWindow else { return manager.activeController }
        return manager.controllers.indices.contains(captureWindow - 1)
            ? manager.controllers[captureWindow - 1]
            : nil
    }

    @MainActor
    private func perform(_ action: Action, in manager: BrowserWindowManager) {
        switch action {
        case .newWindow(let value):
            let start = value == "start" || BrowserAddressResolver.isStartPage(URL(string: value))
            manager.newWindow(url: start ? nil : value)
            return
        case .activateWindow(let number):
            guard manager.controllers.indices.contains(number - 1) else {
                print("snapshot: no window \(number)")
                return
            }
            manager.windowBecameActive(manager.controllers[number - 1])
            return
        case let .moveTab(from, tab, to):
            moveTab(from: from, tab: tab, to: to, in: manager)
            return
        case .waitDownloads:
            let downloads = manager.downloadManager
            Self.spin(120) { !downloads.hasActiveDownloads }
            return
        case .printWindows:
            print(Self.windows(manager))
            return
        case .reopenClosed:
            manager.reopenMostRecent()
            return
        default:
            break
        }
        guard let controller = manager.activeController else {
            print("snapshot: no window is open")
            return
        }
        switch action {
        case .visit(let value):
            if let tab = controller.selectedTab {
                controller.navigate(tab, to: value)
            }
        case .select(let number):
            controller.selectTab(index: number - 1, focus: false)
        case .closeTab:
            controller.closeSelectedTab()
        case .duplicate:
            if let tab = controller.selectedTab {
                controller.duplicateTab(id: tab.id)
            }
        case .goBack:
            controller.goBack()
        case .reload:
            controller.reload()
        case .closeWindow:
            Self.close(controller, in: manager)
        case .startDownload(let value):
            guard let url = URL(string: value) else { return }
            let store = manager.downloads
            let before = Set(store.records.map(\.id))
            controller.startDownload(URLRequest(url: url))
            Self.spin(10) { store.records.contains { !before.contains($0.id) } }
            let started = store.records.first { !before.contains($0.id) }
            print("download: started \(started?.filename ?? "nothing") in window \(manager.number(of: controller) ?? 0)")
        case .crash:
            if let webView = controller.selectedTab?.webView,
               let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
               pid > 0
            {
                kill(pid, SIGKILL)
            }
        case .crashPage:
            if let tab = controller.selectedTab {
                controller.showCrashPage(tab)
            }
        case .newWindow, .activateWindow, .moveTab, .waitDownloads, .printWindows, .reopenClosed:
            break
        }
    }

    /// Detach from one window, attach to another: the move a later Move Tab
    /// to Window uses.
    @MainActor
    private func moveTab(from: Int, tab number: Int, to: Int, in manager: BrowserWindowManager) {
        let windows = manager.controllers
        guard windows.indices.contains(from - 1), windows.indices.contains(to - 1),
              windows[from - 1].tabs.indices.contains(number - 1)
        else {
            print("snapshot: cannot move tab \(number) of window \(from) to window \(to)")
            return
        }
        let source = windows[from - 1]
        let target = windows[to - 1]
        let tab = source.tabs[number - 1]
        source.detachTab(tab)
        target.attachTab(tab, select: true)
        manager.windowBecameActive(target)
        if source.tabs.isEmpty {
            Self.close(source, in: manager)
        }
        print("move-tab: \(tab.displayTitle) from window \(from) to window \(manager.number(of: target) ?? to)")
    }

    @MainActor
    private static func tabInfo(_ tab: BrowserTab, selected: Bool) -> [String: Any] {
        let list = tab.webView.backForwardList
        return [
            "selected": selected,
            "title": tab.displayTitle,
            "url": tab.state.url ?? "about:start",
            "loadedURL": tab.webView.url?.absoluteString ?? NSNull(),
            "restorePending": tab.isRestorePending,
            "canGoBack": tab.webView.canGoBack,
            "canGoForward": tab.webView.canGoForward,
            "back": list.backList.map(\.url.absoluteString),
            "forward": list.forwardList.map(\.url.absoluteString),
            "crashPage": tab.lifecycle.crashView != nil,
            "blockedPopups": tab.links.blockedPopups.map(\.absoluteString),
            "favicon": tab.favicon != nil,
        ]
    }

    @MainActor
    private static func dump(_ controller: BrowserWindowController) -> String {
        let tabs: [[String: Any]] = controller.tabs.enumerated().map { index, tab in
            var info = tabInfo(tab, selected: tab.id == controller.selectedTab?.id)
            info["index"] = index + 1
            return info
        }
        return json(["tabs": tabs, "recentlyClosed": controller.manager.recentlyClosed.count])
    }

    @MainActor
    private static func windows(_ manager: BrowserWindowManager) -> String {
        let active = manager.activeController
        let windows: [[String: Any]] = manager.controllers.enumerated().map { index, controller in
            let frame = manager.sessionFrame(of: controller) ?? .zero
            return [
                "number": index + 1,
                "active": controller === active,
                "title": controller.window?.title ?? "",
                "onScreen": controller.window.map { window in
                    NSScreen.screens.contains { $0.frame.intersects(window.frame) }
                } ?? false,
                "isKey": controller.window?.isKeyWindow ?? false,
                "frame": [
                    "x": frame.origin.x, "y": frame.origin.y,
                    "width": frame.width, "height": frame.height,
                ],
                "tabs": controller.tabs.map { tabInfo($0, selected: $0.id == controller.selectedTab?.id) },
            ]
        }
        let closed: [[String: Any]] = manager.recentlyClosed.newestFirst.map { entry in
            switch entry.content {
            case .tab(let state, _, let index):
                return ["kind": "tab", "title": entry.title, "url": state.url ?? "about:start", "index": index ?? NSNull()]
            case .window(let state):
                return ["kind": "window", "title": entry.title, "tabs": state.tabs.map { $0.url ?? "about:start" }]
            }
        }
        let downloads: [[String: Any]] = manager.downloads.records.map { record in
            [
                "filename": record.filename,
                "state": record.state.rawValue,
                "progress": Int((record.fractionCompleted * 100).rounded()),
            ]
        }
        // A closed window's controller must be released (no retain cycle
        // through stores, tabs or handlers); it is gone by the next turn.
        let alive = closedWindows.filter { $0.controller != nil }.count
        return json([
            "windows": windows,
            "recentlyClosed": closed,
            "downloads": downloads,
            "closedWindowsStillAlive": alive,
        ])
    }

    private struct WeakController {
        weak var controller: BrowserWindowController?
    }

    @MainActor private static var closedWindows: [WeakController] = []

    @MainActor
    private static func close(_ controller: BrowserWindowController, in manager: BrowserWindowManager) {
        closedWindows.append(WeakController(controller: controller))
        manager.closeWindow(controller)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func spin(_ seconds: Double, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            // Each turn drains its autorelease pool, as NSApp's event loop
            // does, so a closed window is released here as in the app.
            autoreleasepool {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date().addingTimeInterval(0.05))
                )
            }
        }
    }
}
