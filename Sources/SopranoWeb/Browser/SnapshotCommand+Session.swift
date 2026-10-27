import AppKit
import WebKit

/// Session and window flags for `SopranoWeb snapshot`. Actions run in the
/// order given, after the initial `--url` load, each followed by `--wait`,
/// on the active window (the most recently opened or activated one):
///
/// - `--session <file>`: restore this session file (version 1, 2 or 3) at
///   launch (a copy; never written back). Every saved window opens.
/// - `--visit <url>`: navigate the selected tab.
/// - `--select <n>`: select tab n (1-based) of the current Space.
/// - `--close-tab`, `--reopen-closed` (⇧⌘T: the active window's in a private
///   window, else the app-wide stack's), `--duplicate`, `--go-back`,
///   `--reload` (⌘R).
/// - `--close-window`: ⇧⌘W on the active window.
/// - `--new-window <url>`: File ▸ New Window, then load `url` (`start` for
///   the start page), in the active window's Space (switch it first with
///   `--space` to open one in another Space). The window stays off every
///   display.
/// - `--new-private-window <url>`: File ▸ New Private Window, likewise, over
///   the active window's Space.
/// - `--create-space <name>` (repeatable): create a Space (with its own
///   profile, the next unused color) through the Space store before any
///   window opens.
/// - `--space <n|name>`: switch the active window to Space n (1-based, as
///   ⌃1…⌃9 count) or the Space named, as `browser space` does.
/// - `--swipe-rail next|previous`: a two-finger sideways swipe over the
///   active window's rail (real scroll events with phases, fingers moving
///   left for next), through the rail's scroll handling.
/// - `--print-spaces`: every Space (number, name, profile id, color, icon,
///   pins) with each window's current Space and tab count in it, as one
///   JSON line.
/// - `--delete-space <name>`: Delete Space on its switcher icon
///   (confirmed): prints the confirmation, closes its tabs and windows,
///   removes its data store and folder; prints the result once the data
///   store removal finished (refused for the Default Space).
/// - `--activate-window <n>`: make window n the active one.
/// - `--move-tab <w>:<t>:<w2>`: detach tab t (of window w's current
///   Space) and attach it to window w2 (selected), the path moving a live
///   tab takes.
/// - `--move-to-new-window`: Window ▸ Move Tab to New Window on the active
///   window's selected tab.
/// - `--drop-tab <w>:<t>:<w2>:<i>`: drop tab t of window w on window w2's
///   tab list at gap i (0 is before the first tab), through the handler
///   the tab list's drag destination calls.
/// - `--drop-outside <w>:<t>:<x>,<y>`: end tab t of window w's drag session
///   where no window takes it, at x,y (the harness screen, as
///   `--print-windows` frames), through the drag source's handler.
/// - `--merge-windows`: Window ▸ Merge All Windows.
/// - `--click-page <X>,<Y>`: a real mouse click into the active window's
///   selected page, X,Y in page points from its top-left corner.
/// - `--find-text <text>`: open the active window's find bar and type.
/// - `--cli "<arguments>"`: run one `browser` CLI request (split on
///   spaces) through the app's router and print its result.
/// - `--start-download <url>`: start a download in the active window and
///   go on without waiting for it; `--wait-downloads` waits for every
///   download to stop.
/// - `--crash`: kill the selected tab's web content process.
/// - `--crash-page`: show the crash page on the selected tab.
/// - `--print-windows`: print every window (kind, its Space and the mark
///   its chrome shows, frame, tabs of every Space with their Space, pin or
///   favorite link and data store, the cookies and website data records of
///   its current Space's data store), the default store's cookies and
///   records, the history count, every Space's data (folder, History, site
///   decisions, its data store's cookies once made), the
///   `WKWebsiteDataStore.allDataStoreIdentifiers`, the favicon files, how
///   many private data stores and web views of closed private windows are
///   still alive, the recently-closed stack and the downloads as one JSON
///   line.
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
        case newPrivateWindow(String)
        case deleteSpace(String)
        case activateWindow(Int)
        case moveTab(from: Int, tab: Int, to: Int)
        case moveToNewWindow
        case dropTab(from: Int, tab: Int, to: Int, index: Int)
        case dropOutside(from: Int, tab: Int, point: NSPoint)
        case mergeWindows
        case clickPage(SnapshotCommand.Click)
        case findText(String)
        case cli(String)
        case startDownload(String)
        case waitDownloads
        case crash
        case crashPage
        case printWindows
        case space(String)
        case swipeRail(next: Bool)
        case printSpaces
        /// Tab sleep and zoom flags (`SnapshotSleepAction`).
        case sleep(SnapshotSleepAction)
        /// Content blocker flags (`SnapshotBlockerAction`).
        case blocker(SnapshotBlockerAction)
        /// Rail flags (`SnapshotRailAction`).
        case rail(SnapshotRailAction)
        /// Archive flags (`SnapshotArchiveAction`).
        case archive(SnapshotArchiveAction)
        /// Command Bar and shortcut flags (`SnapshotCommandBarAction`).
        case commandBar(SnapshotCommandBarAction)
        /// Little Arc flags (`SnapshotLittleArcAction`).
        case littleArc(SnapshotLittleArcAction)
    }

    static let flags: Set<String> = Set([
        "--session", "--visit", "--select", "--close-tab", "--reopen-closed", "--duplicate",
        "--go-back", "--reload", "--close-window", "--new-window", "--new-private-window",
        "--activate-window", "--move-tab",
        "--move-to-new-window", "--drop-tab", "--drop-outside", "--merge-windows", "--click-page",
        "--find-text", "--cli",
        "--start-download", "--wait-downloads", "--crash", "--crash-page", "--print-windows",
        "--dump-tabs", "--save-session", "--capture-window",
        "--create-space", "--space", "--swipe-rail", "--print-spaces", "--delete-space",
    ]).union(SnapshotSleepAction.flags).union(SnapshotBlockerAction.flags).union(SnapshotRailAction.flags)
        .union(SnapshotArchiveAction.flags).union(SnapshotLittleArcAction.flags)
    static let usage = """
                               [--session <file>] [--visit <url>] [--select <n>] [--close-tab]
                               [--reopen-closed] [--duplicate] [--go-back] [--reload]
                               [--close-window] [--new-window <url>]...
                               [--new-private-window <url>]... [--activate-window <n>]
                               [--move-tab <window>:<tab>:<window>] [--move-to-new-window]
                               [--drop-tab <window>:<tab>:<window>:<gap>]
                               [--drop-outside <window>:<tab>:<x>,<y>] [--merge-windows]
                               [--click-page X,Y] [--find-text <text>] [--cli "<arguments>"]
                               [--start-download <url>]
                               [--wait-downloads] [--crash] [--crash-page] [--print-windows]
                               [--dump-tabs] [--save-session <file>] [--capture-window <n>]
                               [--create-space <name>]... [--delete-space <name>]
                               [--space <n|name>] [--swipe-rail next|previous] [--print-spaces]
    \(SnapshotRailAction.usage)
    \(SnapshotArchiveAction.usage)
    \(SnapshotLittleArcAction.usage)
    \(SnapshotCommandBarAction.usage)
    """

    var restoreFrom: URL?
    var actions: [Action] = []
    var dumpTabs = false
    var saveTo: URL?
    var captureWindow: Int?
    /// `--create-space`: made before the first window.
    var spacesToCreate: [String] = []

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
        case "--new-private-window": actions.append(.newPrivateWindow(try value()))
        case "--activate-window": actions.append(.activateWindow(try number()))
        case "--move-tab":
            let raw = try value()
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 > 0 }) else {
                throw SnapshotCommand.OptionError.unknownOption("--move-tab \(raw)")
            }
            actions.append(.moveTab(from: parts[0], tab: parts[1], to: parts[2]))
        case "--move-to-new-window": actions.append(.moveToNewWindow)
        case "--drop-tab":
            let raw = try value()
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 4, parts[0...2].allSatisfy({ $0 > 0 }), parts[3] >= 0 else {
                throw SnapshotCommand.OptionError.unknownOption("--drop-tab \(raw)")
            }
            actions.append(.dropTab(from: parts[0], tab: parts[1], to: parts[2], index: parts[3]))
        case "--drop-outside":
            let raw = try value()
            let parts = raw.split(separator: ":")
            let coordinates = parts.count == 3 ? parts[2].split(separator: ",").compactMap { Double($0) } : []
            guard parts.count == 3, let from = Int(parts[0]), let tab = Int(parts[1]), from > 0, tab > 0,
                  coordinates.count == 2
            else {
                throw SnapshotCommand.OptionError.unknownOption("--drop-outside \(raw)")
            }
            actions.append(.dropOutside(from: from, tab: tab, point: NSPoint(x: coordinates[0], y: coordinates[1])))
        case "--merge-windows": actions.append(.mergeWindows)
        case "--click-page":
            let raw = try value()
            guard let click = SnapshotCommand.Click.parse(raw) else {
                throw SnapshotCommand.OptionError.unknownOption("--click-page \(raw)")
            }
            actions.append(.clickPage(click))
        case "--find-text": actions.append(.findText(try value()))
        case "--cli": actions.append(.cli(try value()))
        case "--start-download": actions.append(.startDownload(try value()))
        case "--wait-downloads": actions.append(.waitDownloads)
        case "--crash": actions.append(.crash)
        case "--crash-page": actions.append(.crashPage)
        case "--print-windows": actions.append(.printWindows)
        case "--dump-tabs": dumpTabs = true
        case "--save-session": saveTo = URL(fileURLWithPath: try value())
        case "--capture-window": captureWindow = try number()
        case "--delete-space": actions.append(.deleteSpace(try value()))
        case "--create-space":
            let name = try value()
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SnapshotCommand.OptionError.unknownOption("--create-space \(name)")
            }
            spacesToCreate.append(name)
        case "--space": actions.append(.space(try value()))
        case "--swipe-rail":
            let raw = try value()
            guard raw == "next" || raw == "previous" else {
                throw SnapshotCommand.OptionError.unknownOption("--swipe-rail \(raw)")
            }
            actions.append(.swipeRail(next: raw == "next"))
        case "--print-spaces": actions.append(.printSpaces)
        default:
            if let action = try SnapshotRailAction.parse(option, value: value) {
                actions.append(.rail(action))
                return
            }
            if let action = try SnapshotArchiveAction.parse(option, value: value) {
                actions.append(.archive(action))
                return
            }
            if let action = try SnapshotLittleArcAction.parse(option, value: value) {
                actions.append(.littleArc(action))
                return
            }
            if let action = try SnapshotBlockerAction.parse(option, value: value) {
                actions.append(.blocker(action))
                return
            }
            guard let action = try SnapshotSleepAction.parse(option, value: value) else {
                throw SnapshotCommand.OptionError.unknownOption(option)
            }
            actions.append(.sleep(action))
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
            autoreleasepool {
                // Private stores and web views about to close are followed
                // until they are released.
                Self.trackPrivateData(in: manager)
                SnapshotSleepAction.trackWebViews(in: manager)
                perform(action, in: manager)
            }
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
        case .sleep(let action):
            action.perform(in: manager)
            return
        case .rail(let action):
            action.perform(in: manager)
            return
        case .archive(let action):
            action.perform(in: manager)
            return
        case .blocker(let action):
            action.perform(in: manager)
            return
        case .commandBar(let action):
            action.perform(in: manager)
            return
        case .littleArc(let action):
            action.perform(in: manager)
            return
        case let .newWindow(value):
            let start = value == "start" || BrowserAddressResolver.isStartPage(URL(string: value))
            manager.newWindow(url: start ? nil : value)
            return
        case .deleteSpace(let name):
            deleteSpace(named: name, in: manager)
            return
        case .newPrivateWindow(let value):
            let start = value == "start" || BrowserAddressResolver.isStartPage(URL(string: value))
            manager.newPrivateWindow(url: start ? nil : value)
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
        case let .dropTab(from, number, to, index):
            guard let (source, tab) = Self.tab(number, ofWindow: from, in: manager),
                  manager.controllers.indices.contains(to - 1)
            else {
                print("snapshot: cannot drop tab \(number) of window \(from) on window \(to)")
                return
            }
            Self.trackIfEmptied(source, by: tab)
            let target = manager.controllers[to - 1]
            let accepted = target.canAcceptDroppedTab(id: tab.id) && target.dropTab(id: tab.id, at: index)
            print("drop-tab: \(tab.displayTitle) on window \(to) at gap \(index): \(accepted ? "accepted" : "refused")")
            return
        case let .dropOutside(from, number, point):
            guard let (source, tab) = Self.tab(number, ofWindow: from, in: manager) else {
                print("snapshot: no tab \(number) in window \(from)")
                return
            }
            Self.trackIfEmptied(source, by: tab)
            let offset = manager.placement.offset
            source.tabDraggedOut(id: tab.id, to: NSPoint(x: point.x + offset.x, y: point.y + offset.y))
            print("drop-outside: \(tab.displayTitle) at \(Int(point.x)),\(Int(point.y))")
            return
        case .mergeWindows:
            let sources = manager.tabbedController.map(manager.mergeSources(into:)) ?? []
            Self.closedWindows += sources.map { WeakController(controller: $0) }
            manager.mergeAllWindows()
            return
        case .cli(let line):
            let arguments = ["SopranoWeb", "browser"] + line.split(separator: " ").map(String.init)
            do {
                guard let request = try BrowserCommandRequest.parse(arguments) else { return }
                var finished = false
                BrowserAutomationRouter.perform(request, in: manager) { result in
                    switch result {
                    case .success(let output): print("cli: \(output)")
                    case .failure(let error): print("cli error: \(error.localizedDescription)")
                    }
                    finished = true
                }
                Self.spin(15) { finished }
            } catch {
                print("cli error: \(error.localizedDescription)")
            }
            return
        case .waitDownloads:
            let downloads = manager.downloadManager
            Self.spin(120) { !downloads.hasActiveDownloads }
            return
        case .printWindows:
            print(Self.windows(manager))
            return
        case .printSpaces:
            print(Self.spaces(manager))
            return
        case .reopenClosed:
            // What ⇧⌘T runs.
            if let controller = manager.activeController {
                controller.reopenClosedTab()
            } else {
                manager.reopenMostRecent()
            }
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
        case .moveToNewWindow:
            if let tab = controller.selectedTab {
                Self.trackIfEmptied(controller, by: tab)
            }
            // What Window ▸ Move Tab to New Window runs.
            controller.moveSelectedTabToNewWindow()
        case .clickPage(let click):
            if let webView = controller.selectedTab?.webView {
                SnapshotCommand.perform(click, in: webView)
            }
        case .findText(let text):
            controller.showFindBar()
            controller.findBar.query = text
            controller.findBar.onQueryChanged?(text)
        case .startDownload(let value):
            guard let url = URL(string: value) else { return }
            let store = manager.downloads
            let before = Set(store.records.map(\.id))
            controller.startDownload(URLRequest(url: url))
            Self.spin(10) { store.records.contains { !before.contains($0.id) } }
            let started = store.records.first { !before.contains($0.id) }
            print("download: started \(started?.filename ?? "nothing") in window \(Self.harnessNumber(of: controller, in: manager))")
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
        case .space(let value):
            // What `browser space` runs on the active window.
            let request = BrowserCommandRequest(command: "space", arguments: [value], tabIndex: nil)
            switch BrowserAutomationRouter.switchSpace(request, in: controller, manager: manager) {
            case .success(let output): print("space: \(output)")
            case .failure(let error): print("space error: \(error.localizedDescription)")
            }
        case .swipeRail(let next):
            Self.swipeRail(next: next, in: controller, manager: manager)
        case .newWindow, .newPrivateWindow, .deleteSpace, .activateWindow, .moveTab, .dropTab, .dropOutside,
             .mergeWindows, .cli, .waitDownloads, .printWindows, .printSpaces, .reopenClosed, .sleep, .blocker, .rail,
             .archive, .commandBar, .littleArc:
            break
        }
    }

    /// `--delete-space`: what Delete Space on the switcher runs once
    /// confirmed; waits for the data store removal.
    @MainActor
    private func deleteSpace(named name: String, in manager: BrowserWindowManager) {
        guard let space = manager.spaces.spaces.first(where: { $0.displayName == name }) else {
            print("delete-space: no Space \(name)")
            return
        }
        guard manager.canDeleteSpace(space.id), let controller = manager.activeController ?? manager.controllers.first else {
            print("delete-space: \(space.displayName) refused (the Default Space stays)")
            return
        }
        let profile = manager.profiles.profile(id: space.profileID) ?? .defaultProfile
        let confirmation = BrowserWindowController.deleteSpaceConfirmation(
            name: space.displayName,
            tabCount: manager.openTabCount(ofProfile: profile.id)
        )
        print("delete-space: \(confirmation.title) \(confirmation.message)")
        let folder = profile.directory(in: manager.supportDirectory)
        // The deleted Space's web views and data store must be released
        // before WebKit lets its data store go; follow them weakly.
        var windows: [WeakController] = []
        var webViews: [WeakObject] = []
        var store = WeakObject(object: nil)
        var finished = false
        var failure: Error?
        // Its own pool, as one turn of the app's event loop: AppKit
        // autoreleases a closing window, and an outer pool (this action's)
        // would keep it, its tabs and their web views until the action ends.
        autoreleasepool {
            let closing = manager.windowsClosing(onDeleteOf: profile.id)
            windows = closing.map { WeakController(controller: $0) }
            // Its tabs in every window, hidden Spaces included.
            webViews = manager.controllers.filter { !$0.kind.isPrivate }.flatMap(\.tabs)
                .filter { $0.dataContext.profileID == profile.id }
                .map { WeakObject(object: $0.webView) }
            store = WeakObject(object: manager.profileContexts[profile.id]?.websiteDataStore)
            controller.deleteSpace(space.id, confirmed: true) { error in
                failure = error
                finished = true
            }
        }
        Self.closedWindows += windows
        Self.spin(15) { finished }
        let identifiers = Self.dataStoreIdentifiers()
        print(
            "delete-space: \(space.displayName) data store removal \(failure.map { "failed: \($0.localizedDescription)" } ?? (finished ? "succeeded" : "timed out")),"
                + " Space still listed: \(manager.spaces.space(id: space.id) != nil),"
                + " identifier still listed: \(identifiers.contains(profile.id)),"
                + " folder still exists: \(FileManager.default.fileExists(atPath: folder.path)),"
                + " windows still alive: \(windows.filter { $0.controller != nil }.count) of \(windows.count),"
                + " web views still alive: \(webViews.filter { $0.object != nil }.count) of \(webViews.count),"
                + " data store object still alive: \(store.object != nil)"
        )
    }

    /// `WKWebsiteDataStore.allDataStoreIdentifiers`: the data stores made
    /// with `WKWebsiteDataStore(forIdentifier:)` that exist on disk.
    @MainActor
    static func dataStoreIdentifiers() -> [UUID] {
        var identifiers: [UUID]?
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers = $0 }
        spin(5) { identifiers != nil }
        return identifiers ?? []
    }

    /// `--move-tab`: the move a dragged tab makes, selected in the target.
    @MainActor
    private func moveTab(from: Int, tab number: Int, to: Int, in manager: BrowserWindowManager) {
        guard let (source, tab) = Self.tab(number, ofWindow: from, in: manager),
              manager.controllers.indices.contains(to - 1)
        else {
            print("snapshot: cannot move tab \(number) of window \(from) to window \(to)")
            return
        }
        let target = manager.controllers[to - 1]
        Self.trackIfEmptied(source, by: tab)
        manager.moveTab(tab, from: source, to: target, at: nil, select: true)
        print("move-tab: \(tab.displayTitle) from window \(from) to window \(manager.number(of: target) ?? to)")
    }

    /// Tab `number` of window `window`'s current Space (as the tab list and
    /// the CLI number them).
    @MainActor
    private static func tab(
        _ number: Int,
        ofWindow window: Int,
        in manager: BrowserWindowManager
    ) -> (BrowserWindowController, BrowserTab)? {
        guard manager.controllers.indices.contains(window - 1) else { return nil }
        let controller = manager.controllers[window - 1]
        guard controller.visibleTabs.indices.contains(number - 1) else { return nil }
        return (controller, controller.visibleTabs[number - 1])
    }

    /// A window about to lose its last tab must be released once it closes
    /// (`closedWindowsStillAlive`).
    @MainActor
    private static func trackIfEmptied(_ controller: BrowserWindowController, by tab: BrowserTab) {
        if controller.tabs.count == 1, controller.tabs.first === tab {
            closedWindows.append(WeakController(controller: controller))
        }
    }

    @MainActor
    private static func tabInfo(_ tab: BrowserTab, in controller: BrowserWindowController) -> [String: Any] {
        let selected = tab.id == controller.selectedTab?.id
        let list = tab.webView.backForwardList
        let manager = controller.manager
        var info: [String: Any] = [
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
            "zoom": tab.zoom,
            "muted": tab.isMuted,
            // The tab's Space (nil in a private or pop-up window), whether
            // it is in the current Space, its pin or favorite link, and the
            // data store it reads and writes.
            "space": tab.spaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull(),
            "spaceID": tab.spaceID?.uuidString ?? NSNull(),
            "visible": controller.visibleTabs.contains { $0 === tab },
            "pin": tab.origin.pinID?.uuidString ?? NSNull(),
            "favorite": tab.origin.favoriteID?.uuidString ?? NSNull(),
            // The Space whose data the tab reads and writes (a private
            // tab's: the Space its window was opened over).
            "dataSpace": manager.spaces.space(ofProfile: tab.dataContext.profileID)?.displayName ?? NSNull(),
            "dataStoreIdentifier": tab.dataContext.websiteDataStore.identifier?.uuidString
                ?? (tab.dataContext.websiteDataStore.isPersistent ? "default" : "nonPersistent"),
        ]
        info.merge(SnapshotSleepAction.tabInfo(tab, in: controller)) { _, new in new }
        return info
    }

    /// The active window's tabs of every Space; `index` counts each tab's
    /// Space.
    @MainActor
    private static func dump(_ controller: BrowserWindowController) -> String {
        let tabs: [[String: Any]] = controller.tabs.map { tab in
            var info = tabInfo(tab, in: controller)
            let spaceTabs = controller.tabs.filter { $0.spaceID == tab.spaceID }
            info["index"] = (spaceTabs.firstIndex { $0 === tab } ?? 0) + 1
            return info
        }
        return json([
            "tabs": tabs,
            "recentlyClosed": controller.manager.recentlyClosed.count,
            "windowClosedTabs": controller.closedTabs.count,
        ])
    }

    /// The window's 1-based place among every window (`--print-windows`
    /// numbers), private ones included.
    @MainActor
    private static func harnessNumber(of controller: BrowserWindowController, in manager: BrowserWindowManager) -> Int {
        (manager.controllers.firstIndex { $0 === controller } ?? -1) + 1
    }

    /// `--create-space`: each Space with a profile of its own, in the
    /// next unused color, through the Space store, before the first
    /// window.
    @MainActor
    func createSpaces(in store: BrowserSpaceStore, profiles: BrowserProfileStore) {
        for name in spacesToCreate {
            let used = Set(store.spaces.map(\.color))
            let color = BrowserProfileColor.allCases.first { !used.contains($0) } ?? .gray
            guard let space = store.createSpace(name: name, color: color, profiles: profiles) else {
                print("snapshot: could not create Space \(name)")
                continue
            }
            print("space: created \(space.displayName) \(space.id.uuidString) (profile \(space.profileID.uuidString))")
        }
    }

    /// `--print-spaces`: every Space with what each window holds of it.
    @MainActor
    private static func spaces(_ manager: BrowserWindowManager) -> String {
        let spaces: [[String: Any]] = manager.spaces.spaces.enumerated().map { index, space in
            let icon = switch space.icon {
            case .none: "none"
            case let .emoji(value): "emoji \(value)"
            case let .symbol(value): "symbol \(value)"
            }
            let windows: [[String: Any]] = manager.controllers.enumerated().compactMap { number, controller in
                guard controller.hasSpaces else { return nil }
                let tabs = controller.tabs.filter { $0.spaceID == space.id }
                return [
                    "window": number + 1,
                    "current": controller.currentSpaceID == space.id,
                    "tabs": tabs.map(\.displayTitle),
                    "selected": controller.spaceSelections[space.id]
                        .flatMap { id in tabs.first { $0.id == id }?.displayTitle } ?? NSNull(),
                ]
            }
            return [
                "number": index + 1,
                "name": space.displayName,
                "id": space.id.uuidString,
                "profileID": space.profileID.uuidString,
                "archiveAfter": manager.profiles.profile(id: space.profileID)?.archiveAfter.rawValue ?? "-",
                "color": space.color.rawValue,
                "icon": icon,
                "pins": manager.spaces.pinEntries(inSpace: space.id).count,
                "windows": windows,
            ]
        }
        return json(["spaces": spaces])
    }

    /// `--swipe-rail`: a two-finger sideways swipe made of real scroll
    /// events (began, three changes, ended; fingers left for the next
    /// Space) through the rail's scroll handling.
    @MainActor
    private static func swipeRail(next: Bool, in controller: BrowserWindowController, manager: BrowserWindowManager) {
        func name(_ id: UUID?) -> String {
            id.flatMap(manager.spaces.space(id:))?.displayName ?? "-"
        }
        let before = controller.currentSpaceID
        // Without natural scrolling, fingers moving left scroll right.
        let step: Int64 = next ? 30 : -30
        let events: [(phase: Int64, delta: Int64)] = [(1, 0), (2, step), (2, step), (2, step), (4, 0)]
        var described: [String] = []
        for (phase, delta) in events {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: Int32(delta),
                wheel3: 0
            ) else { continue }
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            described.append("\(event.phase.rawValue):\(Int(event.scrollingDeltaX))")
            controller.verticalTabsView.scrollWheel(with: event)
        }
        print("swipe-rail: \(next ? "next" : "previous") events \(described.joined(separator: " ")): \(name(before)) -> \(name(controller.currentSpaceID))")
    }

    @MainActor
    private static func windows(_ manager: BrowserWindowManager) -> String {
        trackPrivateData(in: manager)
        SnapshotSleepAction.trackWebViews(in: manager)
        let active = manager.activeController
        let windows: [[String: Any]] = manager.controllers.enumerated().map { index, controller in
            let frame = manager.sessionFrame(of: controller) ?? .zero
            let page = controller.selectedTab?.webView.bounds.size ?? .zero
            return [
                "number": index + 1,
                "cliNumber": manager.number(of: controller) ?? NSNull(),
                "kind": controller.kind.rawValue,
                "active": controller === active,
                "popup": controller.role == .popup,
                "role": controller.role.rawValue,
                "littleSpace": controller.littleSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull(),
                "title": controller.window?.title ?? "",
                // The Space whose data the window uses (a private window's:
                // the one it was opened over) and that data's profile id.
                "dataSpace": manager.space(of: controller)?.displayName ?? NSNull(),
                "profileID": controller.profileID.uuidString,
                // The Space the window shows (nil: private or pop-up) and
                // each Space's remembered tab.
                "currentSpace": controller.currentSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull(),
                "currentSpaceID": controller.currentSpaceID?.uuidString ?? NSNull(),
                "spaceSelections": Dictionary(controller.spaceSelections.compactMap { spaceID, tabID in
                    manager.spaces.space(id: spaceID).map { space in
                        (space.displayName, controller.tabs.first { $0.id == tabID }?.displayTitle ?? "?")
                    }
                }, uniquingKeysWith: { first, _ in first }),
                // The mark the chrome shows: before the address field
                // (horizontal tabs, nil when hidden) and in the rail header.
                "toolbarMark": controller.toolbar.windowMark.isHidden
                    ? NSNull() as Any : controller.toolbar.windowMark.text as Any,
                "railHeader": controller.verticalTabsView.headerText,
                "onScreen": controller.window.map { window in
                    NSScreen.screens.contains { $0.frame.intersects(window.frame) }
                } ?? false,
                "isKey": controller.window?.isKeyWindow ?? false,
                "frame": [
                    "x": frame.origin.x, "y": frame.origin.y,
                    "width": frame.width, "height": frame.height,
                ],
                "pageSize": ["width": page.width, "height": page.height],
                "find": controller.findBar.isHidden ? NSNull() as Any : controller.findQuery as Any,
                "tabs": controller.tabs.map { tabInfo($0, in: controller) },
                "closedTabs": controller.closedTabs.newestFirst.map(\.title),
                // The current Space's profile's store.
                "dataStore": storeContents(controller.dataContext.websiteDataStore),
                "sharesDefaultStore": controller.dataContext.websiteDataStore === WKWebsiteDataStore.default(),
                "dataStoreIdentifier": controller.dataContext.websiteDataStore.identifier?.uuidString ?? NSNull(),
            ]
        }
        let closed: [[String: Any]] = manager.recentlyClosed.newestFirst.map { entry in
            let dataSpace = manager.spaces.space(ofProfile: entry.profileID)?.displayName ?? "(deleted)"
            switch entry.content {
            case .tab(let state, _, let index):
                return ["kind": "tab", "title": entry.title, "url": state.url ?? "about:start", "index": index ?? NSNull(),
                        "dataSpace": dataSpace,
                        "space": state.spaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull()]
            case .window(let state):
                return ["kind": "window", "title": entry.title, "tabs": state.tabs.map { $0.url ?? "about:start" },
                        "dataSpace": dataSpace]
            }
        }
        // Every Space's data: its profile's folder, History, site
        // decisions and data store.
        let spaceData: [[String: Any]] = manager.profiles.profiles.map { profile in
            let folder = profile.directory(in: manager.supportDirectory)
            let history = manager.history(for: profile)
            // The hosts in the profile's saved `site-permissions.json`.
            let decisions = (try? Data(contentsOf: folder.appendingPathComponent("site-permissions.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["sites"] as? [String: Any] }
            // The data store's contents once a window made it (Default's is
            // the default store).
            let context = profile.isDefault ? manager.defaultContext : manager.profileContexts[profile.id]
            return [
                "space": manager.spaces.space(ofProfile: profile.id)?.displayName ?? NSNull(),
                "name": profile.name,
                "id": profile.id.uuidString,
                "color": profile.color.rawValue,
                "folder": folder.path,
                "folderExists": FileManager.default.fileExists(atPath: folder.path),
                "historyDatabase": history.databaseURL.path,
                "historyCount": history.visitCount(),
                "historyURLs": history.visits(limit: 50).map(\.url),
                "siteDecisions": decisions.map { $0.keys.sorted() } ?? [],
                // Saved values per host (zoom, keep awake, decisions).
                "savedSites": decisions ?? [:],
                "dataStore": context.map { storeContents($0.websiteDataStore) as Any } ?? NSNull(),
            ]
        }
        let downloads: [[String: Any]] = manager.downloads.records.map { record in
            [
                "filename": record.filename,
                "state": record.state.rawValue,
                "progress": Int((record.fractionCompleted * 100).rounded()),
                "private": record.privateContextID != nil,
                "profile": record.profileID.uuidString,
            ]
        }
        // A closed window's controller must be released (no retain cycle
        // through stores, tabs or handlers); it is gone by the next turn.
        let alive = closedWindows.filter { $0.controller != nil }.count
        let openStores = manager.controllers.map(\.dataContext.websiteDataStore)
        let openWebViews = manager.controllers.flatMap { $0.tabs.map(\.webView) }
        let faviconFiles = manager.faviconStore.directory.flatMap {
            try? FileManager.default.contentsOfDirectory(atPath: $0.path)
        } ?? []
        let session = manager.currentSession
        return json([
            "windows": windows,
            // Lines up the output with a test server's request log.
            "printedAt": Date().timeIntervalSince1970,
            "recentlyClosed": closed,
            "downloads": downloads,
            "closedWindowsStillAlive": alive,
            "historyCount": manager.defaultContext.history.visitCount(),
            "historyURLs": manager.defaultContext.history.visits(limit: 50).map(\.url),
            "spaceData": spaceData,
            "dataStoreIdentifiers": dataStoreIdentifiers().map(\.uuidString).sorted(),
            "profileFolders": (try? FileManager.default.contentsOfDirectory(
                atPath: manager.supportDirectory.appendingPathComponent(BrowserProfile.folderName).path
            ))?.sorted() ?? [],
            "defaultStore": storeContents(.default()),
            "faviconFiles": faviconFiles.sorted(),
            "sessionWindows": session.windows.map { $0.tabs.map { $0.url ?? "about:start" } },
            // What the session saves of each window's Spaces (version 3).
            "sessionSpaces": session.windows.map { window -> [String: Any] in
                [
                    "currentSpace": window.currentSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull(),
                    "tabSpaces": window.tabs.map { $0.spaceID.flatMap(manager.spaces.space(id:))?.displayName ?? "-" },
                    "selections": window.spaceSelections.count,
                ]
            },
            "privateStoresTracked": trackedPrivateStores.count,
            "closedPrivateStoresStillAlive": trackedPrivateStores.filter { weak in
                guard let store = weak.object else { return false }
                return !openStores.contains { $0 === store }
            }.count,
            "privateWebViewsTracked": trackedPrivateWebViews.count,
            "closedPrivateWebViewsStillAlive": trackedPrivateWebViews.filter { weak in
                guard let webView = weak.object else { return false }
                return !openWebViews.contains { $0 === webView }
            }.count,
            // Tab sleep: the web views every tab ever had, which of the
            // replaced ones are still alive and their content processes.
            "webViews": SnapshotSleepAction.webViewReport(in: manager),
        ])
    }

    /// Cookies (`name=value`) and website data record names of `store`.
    @MainActor
    private static func storeContents(_ store: WKWebsiteDataStore) -> [String: Any] {
        var cookies: [String]?
        var records: [String]?
        store.httpCookieStore.getAllCookies { list in
            cookies = list.map { "\($0.name)=\($0.value)" }.sorted()
        }
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { list in
            records = list.map(\.displayName).sorted()
        }
        spin(5) { cookies != nil && records != nil }
        return ["cookies": cookies ?? [], "records": records ?? []]
    }

    private struct WeakObject {
        weak var object: AnyObject?
    }

    @MainActor private static var trackedPrivateStores: [WeakObject] = []
    @MainActor private static var trackedPrivateWebViews: [WeakObject] = []

    /// Remembers every private window's data store and web views, weakly,
    /// so `--print-windows` can tell whether closed ones were released.
    @MainActor
    static func trackPrivateData(in manager: BrowserWindowManager) {
        for controller in manager.controllers where controller.kind.isPrivate {
            let store = controller.dataContext.websiteDataStore
            if !trackedPrivateStores.contains(where: { $0.object === store }) {
                trackedPrivateStores.append(WeakObject(object: store))
            }
            for tab in controller.tabs where !trackedPrivateWebViews.contains(where: { $0.object === tab.webView }) {
                trackedPrivateWebViews.append(WeakObject(object: tab.webView))
            }
        }
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
