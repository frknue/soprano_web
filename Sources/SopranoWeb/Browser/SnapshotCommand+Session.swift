import AppKit
import WebKit

/// Session flags for `SopranoWeb snapshot`. Actions run in the order given,
/// after the initial `--url` load, each followed by `--wait`:
///
/// - `--session <file>`: restore this session file at launch (a copy; never
///   written back).
/// - `--visit <url>`: navigate the selected tab.
/// - `--select <n>`: select tab n (1-based).
/// - `--close-tab`, `--reopen-closed`, `--duplicate`, `--go-back`, `--reload` (⌘R).
/// - `--close-window`: ⇧⌘W's tab handling (the window stays for the capture).
/// - `--crash`: kill the selected tab's web content process.
/// - `--crash-page`: show the crash page on the selected tab.
/// - `--dump-tabs`: print the tabs as one JSON line after the actions.
/// - `--save-session <file>`: write the window's session after the actions.
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
        case crash
        case crashPage
    }

    static let flags: Set<String> = [
        "--session", "--visit", "--select", "--close-tab", "--reopen-closed", "--duplicate",
        "--go-back", "--reload", "--close-window", "--crash", "--crash-page", "--dump-tabs",
        "--save-session",
    ]
    static let usage = """
                               [--session <file>] [--visit <url>] [--select <n>] [--close-tab]
                               [--reopen-closed] [--duplicate] [--go-back] [--reload]
                               [--close-window] [--crash] [--crash-page] [--dump-tabs]
                               [--save-session <file>]
    """

    var restoreFrom: URL?
    var actions: [Action] = []
    var dumpTabs = false
    var saveTo: URL?

    var restoresSession: Bool { restoreFrom != nil }

    mutating func parse(_ option: String, value: () throws -> String) throws {
        switch option {
        case "--session": restoreFrom = URL(fileURLWithPath: try value())
        case "--visit": actions.append(.visit(try value()))
        case "--select":
            let raw = try value()
            guard let number = Int(raw), number > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--select \(raw)")
            }
            actions.append(.select(number))
        case "--close-tab": actions.append(.closeTab)
        case "--reopen-closed": actions.append(.reopenClosed)
        case "--duplicate": actions.append(.duplicate)
        case "--go-back": actions.append(.goBack)
        case "--reload": actions.append(.reload)
        case "--close-window": actions.append(.closeWindow)
        case "--crash": actions.append(.crash)
        case "--crash-page": actions.append(.crashPage)
        case "--dump-tabs": dumpTabs = true
        case "--save-session": saveTo = URL(fileURLWithPath: try value())
        default: throw SnapshotCommand.OptionError.unknownOption(option)
        }
    }

    /// Copies the session file to where the harness's volatile store reads it.
    func prepare(sessionURL: URL) {
        guard let restoreFrom else { return }
        try? FileManager.default.copyItem(at: restoreFrom, to: sessionURL)
    }

    @MainActor
    func run(_ controller: BrowserWindowController, wait seconds: Double) {
        for action in actions {
            perform(action, on: controller)
            Self.spin(seconds)
        }
        if dumpTabs {
            print(Self.dump(controller))
        }
        if let saveTo {
            try? JSONFile.write(controller.currentSession, to: saveTo)
        }
    }

    @MainActor
    private func perform(_ action: Action, on controller: BrowserWindowController) {
        switch action {
        case .visit(let value):
            if let tab = controller.selectedTab {
                controller.navigate(tab, to: value)
            }
        case .select(let number):
            controller.selectTab(index: number - 1, focus: false)
        case .closeTab:
            controller.closeSelectedTab()
        case .reopenClosed:
            controller.reopenClosedTab()
        case .duplicate:
            if let tab = controller.selectedTab {
                controller.duplicateTab(id: tab.id)
            }
        case .goBack:
            controller.goBack()
        case .reload:
            controller.reload()
        case .closeWindow:
            controller.closeAllTabs()
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
        }
    }

    @MainActor
    private static func dump(_ controller: BrowserWindowController) -> String {
        let tabs: [[String: Any]] = controller.tabs.enumerated().map { index, tab in
            let list = tab.webView.backForwardList
            return [
                "index": index + 1,
                "selected": tab.id == controller.selectedTab?.id,
                "title": tab.displayTitle,
                "url": tab.state.url ?? "about:start",
                "loadedURL": tab.webView.url?.absoluteString ?? NSNull(),
                "restorePending": tab.isRestorePending,
                "canGoBack": tab.webView.canGoBack,
                "canGoForward": tab.webView.canGoForward,
                "back": list.backList.map(\.url.absoluteString),
                "forward": list.forwardList.map(\.url.absoluteString),
                "crashPage": tab.lifecycle.crashView != nil,
            ]
        }
        let object: [String: Any] = ["tabs": tabs, "closedTabs": controller.closedTabs.count]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func spin(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }
    }
}
