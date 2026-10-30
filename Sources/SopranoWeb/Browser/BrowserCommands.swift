import AppKit

/// Every command of the app, by a stable id: what `settings.json`'s
/// `shortcuts` keys, the menu items' identifiers and the harness name.
enum BrowserCommandID: String, CaseIterable, Sendable {
    case about, settings, hide, hideOthers = "hide-others", showAll = "show-all", quit
    case newTab = "new-tab", newWindow = "new-window", newPrivateWindow = "new-private-window"
    case newLittleArc = "new-little-arc", openInSpaceWindow = "open-in-space-window"
    case reopenClosed = "reopen-closed", openLocation = "open-location"
    case closeTab = "close-tab", closeWindow = "close-window"
    case saveAs = "save-as", exportPDF = "export-pdf", print, capture
    case importBrowserData = "import-browser-data", exportPins = "export-pins"
    case undo, redo, cut, copy, paste, selectAll = "select-all"
    case find, findNext = "find-next", findPrevious = "find-previous"
    case copyURL = "copy-url", copyMarkdown = "copy-markdown"
    case searchActions = "search-actions"
    case back, forward, home, reload, stop
    case zoomIn = "zoom-in", zoomOut = "zoom-out", actualSize = "actual-size"
    case toggleSidebar = "toggle-sidebar", toggleRail = "toggle-rail", toggleToolbar = "toggle-toolbar"
    case fullScreen = "full-screen"
    case splitAdd = "split-add", splitClose = "split-close"
    case splitPane1 = "split-pane-1", splitPane2 = "split-pane-2", splitPane3 = "split-pane-3"
    case splitPane4 = "split-pane-4"
    case showHistory = "show-history", showArchive = "show-archive", showDownloads = "show-downloads"
    case clearBrowsingData = "clear-browsing-data"
    case space1 = "space-1", space2 = "space-2", space3 = "space-3", space4 = "space-4", space5 = "space-5"
    case space6 = "space-6", space7 = "space-7", space8 = "space-8", space9 = "space-9"
    case nextSpace = "next-space", previousSpace = "previous-space"
    case pinPage = "pin-page", showPinnedTabs = "show-pinned-tabs", archiveToday = "archive-today"
    case minimize, zoomWindow = "zoom-window"
    case recentTab = "recent-tab", recentTabBack = "recent-tab-back"
    case nextTab = "next-tab", previousTab = "previous-tab"
    case moveTabToNewWindow = "move-tab-to-new-window", mergeAllWindows = "merge-all-windows"
    case tab1 = "tab-1", tab2 = "tab-2", tab3 = "tab-3", tab4 = "tab-4", tab5 = "tab-5", tab6 = "tab-6"
    case tab7 = "tab-7", tab8 = "tab-8", lastTab = "last-tab"
    case bringAllToFront = "bring-all-to-front"
    case keyboardShortcuts = "keyboard-shortcuts"
    case editBoost = "edit-boost", zapElements = "zap-elements"
    case reader, translatePage = "translate-page"

    var command: BrowserAppCommand { BrowserAppCommand.byID[self]! }
    var defaultShortcut: BrowserShortcut? { command.shortcut }
    /// Standard AppKit commands (Copy, Quit, Minimize…) keep their keys.
    var isRemappable: Bool { command.systemAction == nil }
}

/// What a command acts on: the window manager and the browser window (the
/// key or most recently active one for the menu bar; the window whose page
/// got the key, or whose Command Bar ran it).
@MainActor
struct BrowserCommandContext {
    let manager: BrowserWindowManager?
    let controller: BrowserWindowController?

    init(manager: BrowserWindowManager?, controller: BrowserWindowController? = nil) {
        self.manager = manager
        self.controller = controller ?? manager?.activeController
    }

    /// The window Space commands switch: the context's, else the active
    /// window with tabs, when it shows Spaces.
    var spaceWindow: BrowserWindowController? {
        if let controller, controller.hasSpaces { return controller }
        return manager?.tabbedController.flatMap { $0.hasSpaces ? $0 : nil }
    }
}

struct BrowserCommandState {
    var isEnabled: Bool
    /// A title for this moment ("Reopen Closed Window", "Show Toolbar").
    var title: String?

    static let enabled = BrowserCommandState(isEnabled: true)
    static let disabled = BrowserCommandState(isEnabled: false)
    static func when(_ condition: Bool) -> BrowserCommandState { condition ? .enabled : .disabled }
}

/// One row of the command registry: the menu bar, Settings ▸ Shortcuts,
/// the Command Bar's `/` actions and the key routing all read this table
/// (`BrowserAppCommand.all`, in menu order).
struct BrowserAppCommand: Sendable {
    enum Menu: String, CaseIterable, Sendable {
        case app = "Soprano Web"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case history = "History"
        case spaces = "Spaces"
        case window = "Window"
        case help = "Help"
    }

    let id: BrowserCommandID
    let title: String
    let menu: Menu
    /// Items of one section sit between separators.
    let section: Int
    let shortcut: BrowserShortcut?
    /// Other words the Command Bar matches.
    let synonyms: [String]
    /// The Command Bar row's SF Symbol.
    let symbol: String
    /// A standard AppKit action sent down the responder chain; such a
    /// command keeps its shortcut and has no Command Bar row.
    let systemAction: String?
    /// A menu item of its own (the Spaces menu draws ⌃1…⌃9 on its Space
    /// items instead).
    let hasMenuItem: Bool
    let inCommandBar: Bool
    let state: @MainActor @Sendable (BrowserCommandContext) -> BrowserCommandState
    let run: @MainActor @Sendable (BrowserCommandContext) -> Void

    @MainActor
    func perform(in context: BrowserCommandContext) {
        if let systemAction {
            NSApp.sendAction(NSSelectorFromString(systemAction), to: nil, from: nil)
        } else {
            run(context)
        }
    }

    /// The menu item's title in `state`: the moment's ("Close Peek"),
    /// else the command's own.
    func menuTitle(for state: BrowserCommandState) -> String {
        state.title ?? title
    }

    // MARK: Table

    static let byID: [BrowserCommandID: BrowserAppCommand] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    private static func make(
        _ id: BrowserCommandID,
        _ title: String,
        _ menu: Menu,
        _ section: Int,
        _ shortcut: String? = nil,
        synonyms: [String] = [],
        symbol: String = "command",
        inBar: Bool = true,
        menuItem: Bool = true,
        state: @escaping @MainActor @Sendable (BrowserCommandContext) -> BrowserCommandState = { _ in .enabled },
        run: @escaping @MainActor @Sendable (BrowserCommandContext) -> Void
    ) -> BrowserAppCommand {
        BrowserAppCommand(
            id: id,
            title: title,
            menu: menu,
            section: section,
            shortcut: shortcut.map { BrowserShortcut($0)! },
            synonyms: synonyms,
            symbol: symbol,
            systemAction: nil,
            hasMenuItem: menuItem,
            inCommandBar: inBar,
            state: state,
            run: run
        )
    }

    private static func system(
        _ id: BrowserCommandID,
        _ title: String,
        _ menu: Menu,
        _ section: Int,
        _ shortcut: String?,
        _ action: String
    ) -> BrowserAppCommand {
        BrowserAppCommand(
            id: id,
            title: title,
            menu: menu,
            section: section,
            shortcut: shortcut.map { BrowserShortcut($0)! },
            synonyms: [],
            symbol: "command",
            systemAction: action,
            hasMenuItem: true,
            inCommandBar: false,
            state: { _ in .enabled },
            run: { _ in }
        )
    }

    /// The window's selected tab has a page whose address can be copied.
    @MainActor
    private static func hasPage(_ context: BrowserCommandContext) -> BrowserCommandState {
        .when(context.controller?.selectedPageURL != nil)
    }

    @MainActor
    private static func hasWindow(_ context: BrowserCommandContext) -> BrowserCommandState {
        .when(context.controller != nil)
    }

    private static func spaceCommand(_ id: BrowserCommandID, number: Int) -> BrowserAppCommand {
        make(
            id, "Switch to Space \(number)", .spaces, 0, "ctrl+\(number)",
            inBar: false, menuItem: false,
            state: { context in
                .when(context.spaceWindow != nil && (context.manager?.spaces.spaces.count ?? 0) >= number)
            },
            run: { context in
                guard let window = context.spaceWindow else { return }
                window.switchToSpace(number: number)
                window.revealWindowIfNeeded()
            }
        )
    }

    private static func tabCommand(_ id: BrowserCommandID, number: Int) -> BrowserAppCommand {
        make(
            id, number == 9 ? "Last Tab" : "Tab \(number)", .window, 2, "cmd+\(number)",
            inBar: false,
            state: hasWindow,
            run: { context in
                if number == 9 {
                    context.controller?.selectLastTab()
                } else {
                    context.controller?.selectTab(number: number)
                }
            }
        )
    }

    /// ⌃⇧1…⌃⇧4: pane `number` of the split on screen.
    private static func splitPaneCommand(_ id: BrowserCommandID, number: Int) -> BrowserAppCommand {
        make(
            id, "Focus Split Pane \(number)", .view, 6, "ctrl+shift+\(number)",
            synonyms: ["split view", "pane \(number)"], symbol: "rectangle.split.2x1", inBar: false,
            state: { .when(($0.controller?.shownSplit?.tabIDs.count ?? 0) >= number) },
            run: { $0.controller?.focusPane(number: number) }
        )
    }

    /// The registry, in menu order.
    static let all: [BrowserAppCommand] = [
        // Soprano Web
        system(.about, "About Soprano Web", .app, 0, nil, "orderFrontStandardAboutPanel:"),
        make(.settings, "Settings…", .app, 1, "cmd+,", synonyms: ["preferences", "options"], symbol: "gearshape") {
            $0.manager?.showSettings()
        },
        system(.hide, "Hide Soprano Web", .app, 2, "cmd+h", "hide:"),
        system(.hideOthers, "Hide Others", .app, 2, "opt+cmd+h", "hideOtherApplications:"),
        system(.showAll, "Show All", .app, 2, nil, "unhideAllApplications:"),
        system(.quit, "Quit Soprano Web", .app, 3, "cmd+q", "terminate:"),

        // File
        make(.newTab, "New Tab", .file, 0, "cmd+t", synonyms: ["open", "command bar"], symbol: "plus") { context in
            guard let controller = context.controller else {
                context.manager?.newWindow()
                return
            }
            controller.showCommandBar(.newTab)
            controller.revealWindowIfNeeded()
        },
        make(.newWindow, "New Window", .file, 0, "cmd+n", symbol: "macwindow") { $0.manager?.newWindow() },
        make(.newPrivateWindow, "New Private Window", .file, 0, "shift+cmd+n", synonyms: ["incognito"],
             symbol: "eyeglasses") { $0.manager?.newPrivateWindow() },
        make(.newLittleArc, "New Little Arc", .file, 0, "opt+cmd+n", synonyms: ["little arc", "quick window"],
             symbol: "macwindow.badge.plus") { $0.manager?.newLittleArc(commandBar: true) },
        // ⌘O: a Peek opens as a tab; a Little Arc's tab moves into its
        // Space's window.
        make(.openInSpaceWindow, "Open in Space Window", .file, 0, "cmd+o",
             synonyms: ["little arc", "move to window", "peek", "open as tab"], symbol: "arrow.up.left.and.arrow.down.right",
             state: { context in
                 if context.controller?.peek != nil {
                     return BrowserCommandState(isEnabled: true, title: "Open Peek as Tab")
                 }
                 return .when(context.controller?.role == .little)
             }) { context in
            guard let controller = context.controller else { return }
            if controller.peek != nil {
                controller.openPeekAsTab()
            } else if controller.role == .little {
                controller.moveLittleArcToSpaceWindow()
            }
        },
        make(
            .reopenClosed, "Reopen Closed Tab", .file, 1, "shift+cmd+t",
            synonyms: ["undo close", "restore tab"], symbol: "arrow.uturn.backward",
            state: { context in
                guard let manager = context.manager else { return .disabled }
                // A private window reopens only its own closed tabs.
                if let controller = context.controller, !controller.kind.usesAppRecentlyClosed {
                    return BrowserCommandState(isEnabled: controller.canReopenClosedTab, title: "Reopen Closed Tab")
                }
                let title = manager.recentlyClosed.newest?.isWindow == true ? "Reopen Closed Window" : "Reopen Closed Tab"
                return BrowserCommandState(isEnabled: !manager.recentlyClosed.isEmpty, title: title)
            },
            run: { context in
                if let controller = context.controller {
                    controller.reopenClosedTab()
                } else {
                    context.manager?.reopenMostRecent()
                }
            }
        ),
        make(.openLocation, "Open Location…", .file, 1, "cmd+l", synonyms: ["address", "url", "edit url"],
             symbol: "character.cursor.ibeam") { context in
            guard let manager = context.manager else { return }
            guard let controller = context.controller else {
                manager.newWindow()
                return
            }
            manager.present(controller)
            controller.showCommandBar(.editCurrent)
        },
        make(.closeTab, "Close Tab", .file, 2, "cmd+w", symbol: "xmark",
             state: { context in
                 if context.controller?.peek != nil {
                     return BrowserCommandState(isEnabled: true, title: "Close Peek")
                 }
                 return .when(!(context.controller?.tabs.isEmpty ?? true))
             }) { $0.controller?.closeSelectedTab() },
        make(
            .closeWindow, "Close Window", .file, 2, "shift+cmd+w", symbol: "macwindow.badge.minus",
            state: { .when(NSApp.keyWindow != nil || $0.controller != nil) },
            run: { context in
                // ⇧⌘W closes the key window: a browser window onto the
                // recently-closed stack, any other window (Settings) the
                // usual way.
                guard let manager = context.manager else { return }
                if let key = NSApp.keyWindow, !manager.controllers.contains(where: { $0.window === key }) {
                    key.performClose(nil)
                } else if let controller = context.controller {
                    manager.closeWindow(controller)
                }
            }
        ),
        make(.saveAs, "Save As…", .file, 3, "shift+cmd+s", synonyms: ["web archive", "download page"],
             symbol: "square.and.arrow.down", state: { .when($0.controller?.canUsePageTools ?? false) }) {
            $0.controller?.saveSelectedPageAs()
        },
        make(.exportPDF, "Export as PDF…", .file, 3, symbol: "doc.richtext",
             state: { .when($0.controller?.canUsePageTools ?? false) }) {
            $0.controller?.exportSelectedPageAsPDF()
        },
        make(.capture, "Capture…", .file, 3, "shift+cmd+2", synonyms: ["screenshot", "full page", "snapshot"],
             symbol: "camera.viewfinder", state: { .when($0.controller?.canCapture ?? false) }) {
            $0.controller?.toggleCaptureOverlay()
        },
        make(.importBrowserData, "Import Browser Data…", .file, 5, synonyms: ["arc", "chrome", "safari", "bookmarks"],
             symbol: "square.and.arrow.down.on.square") { context in
            context.manager?.showImportSheet(from: context.controller)
        },
        make(.exportPins, "Export Pinned Tabs…", .file, 5, synonyms: ["bookmarks", "html"],
             symbol: "square.and.arrow.up", state: { .when($0.controller?.pinSpaceID != nil) }) {
            $0.controller?.exportPinnedTabs()
        },
        make(.print, "Print…", .file, 4, "cmd+p", symbol: "printer",
             state: { .when($0.controller?.canUsePageTools ?? false) }) {
            $0.controller?.printSelectedPage()
        },

        // Edit
        system(.undo, "Undo", .edit, 0, "cmd+z", "undo:"),
        system(.redo, "Redo", .edit, 0, "shift+cmd+z", "redo:"),
        system(.cut, "Cut", .edit, 1, "cmd+x", "cut:"),
        system(.copy, "Copy", .edit, 1, "cmd+c", "copy:"),
        system(.paste, "Paste", .edit, 1, "cmd+v", "paste:"),
        system(.selectAll, "Select All", .edit, 1, "cmd+a", "selectAll:"),
        make(.find, "Find…", .edit, 2, "cmd+f", synonyms: ["search page"], symbol: "magnifyingglass",
             state: hasWindow) { $0.controller?.showFindBar() },
        make(.findNext, "Find Next", .edit, 2, "cmd+g", symbol: "chevron.down", state: hasWindow) {
            $0.controller?.findNext()
        },
        make(.findPrevious, "Find Previous", .edit, 2, "shift+cmd+g", symbol: "chevron.up", state: hasWindow) {
            $0.controller?.findPrevious()
        },
        make(.copyURL, "Copy URL", .edit, 3, "shift+cmd+c", synonyms: ["copy link", "copy address"],
             symbol: "link", state: hasPage) { _ = $0.controller?.copyPageAddress(markdown: false) },
        make(.copyMarkdown, "Copy URL as Markdown", .edit, 3, "opt+shift+cmd+c", synonyms: ["copy link markdown"],
             symbol: "text.badge.plus", state: hasPage) { _ = $0.controller?.copyPageAddress(markdown: true) },

        // View
        make(.searchActions, "Search Actions…", .view, 0, "shift+cmd+p", synonyms: ["command palette", "commands"],
             symbol: "command", inBar: false, state: hasWindow) { $0.controller?.showCommandBar(.actions) },
        make(.back, "Back", .view, 1, "cmd+[", symbol: "chevron.left",
             state: { .when($0.controller?.pageTab?.webView.canGoBack ?? false) }) { $0.controller?.goBack() },
        make(.forward, "Forward", .view, 1, "cmd+]", symbol: "chevron.right",
             state: { .when($0.controller?.pageTab?.webView.canGoForward ?? false) }) {
            $0.controller?.goForward()
        },
        make(.home, "Home", .view, 1, "shift+cmd+h", synonyms: ["start page"], symbol: "house", state: hasWindow) {
            $0.controller?.goHome()
        },
        make(.reload, "Reload", .view, 2, "cmd+r", synonyms: ["refresh"], symbol: "arrow.clockwise",
             state: hasWindow) { $0.controller?.reloadOrStop() },
        make(.stop, "Stop", .view, 2, "cmd+.", symbol: "xmark.circle",
             state: { .when($0.controller?.isPageLoading ?? false) }) { $0.controller?.stopLoading() },
        make(.zoomIn, "Zoom In", .view, 3, "cmd+=", synonyms: ["bigger"], symbol: "plus.magnifyingglass",
             state: hasWindow) { $0.controller?.zoomIn() },
        make(.zoomOut, "Zoom Out", .view, 3, "cmd+-", synonyms: ["smaller"], symbol: "minus.magnifyingglass",
             state: hasWindow) { $0.controller?.zoomOut() },
        make(.actualSize, "Actual Size", .view, 3, "cmd+0", synonyms: ["reset zoom"], symbol: "1.magnifyingglass",
             state: hasWindow) { $0.controller?.resetZoom() },
        make(.toggleSidebar, "Toggle Sidebar", .view, 4, "shift+cmd+b", synonyms: ["right sidebar"],
             symbol: "sidebar.right", state: hasWindow) { $0.controller?.toggleSidebar() },
        make(.toggleRail, "Toggle Vertical Sidebar", .view, 4, "cmd+s", synonyms: ["rail", "vertical tabs"],
             symbol: "sidebar.left", state: hasWindow) { $0.controller?.toggleVerticalSidebar() },
        make(
            .toggleToolbar, "Hide Toolbar", .view, 4, "shift+cmd+d", synonyms: ["toolbar", "address bar"],
            symbol: "menubar.rectangle",
            state: { context in
                guard let controller = context.controller else { return .disabled }
                return BrowserCommandState(
                    isEnabled: !controller.role.isCompact,
                    title: controller.isToolbarHidden ? "Show Toolbar" : "Hide Toolbar"
                )
            },
            run: { $0.controller?.toggleToolbar() }
        ),
        system(.fullScreen, "Enter Full Screen", .view, 5, "ctrl+cmd+f", "toggleFullScreen:"),
        make(
            .splitAdd, "Add Split Pane", .view, 6, "ctrl+shift+=", synonyms: ["split view", "side by side", "new pane"],
            symbol: "rectangle.split.2x1",
            state: { context in
                guard let controller = context.controller else { return .disabled }
                return .when(controller.allowsSplits && !(controller.shownSplit?.isFull ?? false))
            },
            run: { $0.controller?.addSplitPane(commandBar: true) }
        ),
        make(
            .splitClose, "Close Split Pane", .view, 6, "ctrl+shift+-", synonyms: ["split view", "close pane"],
            symbol: "xmark.rectangle",
            state: { .when($0.controller?.shownSplit != nil) },
            run: { $0.controller?.closeFocusedPane() }
        ),
        splitPaneCommand(.splitPane1, number: 1),
        splitPaneCommand(.splitPane2, number: 2),
        splitPaneCommand(.splitPane3, number: 3),
        splitPaneCommand(.splitPane4, number: 4),
        make(.editBoost, "Boost This Site…", .view, 7, synonyms: ["boost", "custom css", "user script"],
             symbol: "paintbrush", state: { .when($0.controller?.boostHost != nil) }) {
            $0.controller?.showBoostEditor()
        },
        make(.zapElements, "Zap Elements", .view, 7, synonyms: ["boost", "zap", "hide element"],
             symbol: "eye.slash", state: { .when($0.controller?.boostHost != nil) }) {
            $0.controller?.startZap()
        },
        make(
            .reader, "Show Reader", .view, 8, "shift+cmd+r", synonyms: ["reader", "reader mode", "article", "read"],
            symbol: "doc.plaintext",
            state: { context in
                guard let controller = context.controller, controller.canToggleReader else { return .disabled }
                return BrowserCommandState(
                    isEnabled: true,
                    title: controller.pageTab?.reader.isActive == true ? "Hide Reader" : "Show Reader"
                )
            },
            run: { $0.controller?.toggleReader() }
        ),
        make(
            .translatePage, "Translate Page", .view, 8, synonyms: ["translate", "translation", "language"],
            symbol: "translate",
            state: { context in
                guard let controller = context.controller, let tab = controller.pageTab else { return .disabled }
                if tab.translation.isTranslated {
                    return BrowserCommandState(isEnabled: controller.canUsePageTools, title: "Show Original")
                }
                return .when(controller.canTranslatePage)
            },
            run: { $0.controller?.toggleTranslation() }
        ),

        // History
        make(.showHistory, "Show All History", .history, 0, "cmd+y", symbol: "clock", state: hasWindow) {
            $0.controller?.showSidebar(section: .history)
        },
        make(.showArchive, "Show Archive", .history, 0, synonyms: ["archived tabs"], symbol: "archivebox",
             state: { .when($0.controller.map { !$0.kind.isPrivate } ?? false) }) {
            $0.controller?.showSidebar(section: .archive)
        },
        make(.showDownloads, "Show Downloads", .history, 0, "opt+cmd+l", symbol: "arrow.down.circle",
             state: hasWindow) { $0.controller?.showSidebar(section: .downloads) },
        make(.clearBrowsingData, "Clear Browsing Data…", .history, 1, "shift+cmd+delete",
             synonyms: ["delete history", "cookies", "cache"], symbol: "trash", state: hasWindow) {
            $0.controller?.showClearBrowsingData()
        },

        // Spaces
        spaceCommand(.space1, number: 1),
        spaceCommand(.space2, number: 2),
        spaceCommand(.space3, number: 3),
        spaceCommand(.space4, number: 4),
        spaceCommand(.space5, number: 5),
        spaceCommand(.space6, number: 6),
        spaceCommand(.space7, number: 7),
        spaceCommand(.space8, number: 8),
        spaceCommand(.space9, number: 9),
        make(
            .nextSpace, "Next Space", .spaces, 1, "opt+cmd+right", symbol: "arrow.right.square",
            state: { .when($0.spaceWindow != nil && ($0.manager?.spaces.spaces.count ?? 0) > 1) },
            run: { $0.spaceWindow?.switchToNeighborSpace(step: 1) }
        ),
        make(
            .previousSpace, "Previous Space", .spaces, 1, "opt+cmd+left", symbol: "arrow.left.square",
            state: { .when($0.spaceWindow != nil && ($0.manager?.spaces.spaces.count ?? 0) > 1) },
            run: { $0.spaceWindow?.switchToNeighborSpace(step: -1) }
        ),
        make(
            .pinPage, "Pin This Page", .spaces, 2, "cmd+d", synonyms: ["bookmark", "pin tab"], symbol: "pin",
            state: { context in
                guard let controller = context.controller, let tab = controller.selectedTab, !tab.isStartPage,
                      let url = tab.webView.url
                else { return .disabled }
                let isPinned = controller.pinSpaceID.map {
                    controller.spaces.isPinned(url.absoluteString, inSpace: $0)
                } ?? false
                return BrowserCommandState(isEnabled: true, title: isPinned ? "Edit Pin" : "Pin This Page")
            },
            run: { $0.controller?.bookmarkCurrentPage() }
        ),
        make(.showPinnedTabs, "Show Pinned Tabs", .spaces, 2, "opt+cmd+b", synonyms: ["rail"], symbol: "pin.circle",
             state: hasWindow) { $0.controller?.showRail() },
        make(.archiveToday, "Archive Today Tabs", .spaces, 2, "shift+cmd+k", synonyms: ["clear today", "archive tabs"],
             symbol: "archivebox", state: { .when($0.controller?.canArchiveTodayTabs ?? false) }) {
            $0.controller?.archiveTodayTabs()
        },

        // Window
        system(.minimize, "Minimize", .window, 0, "cmd+m", "performMiniaturize:"),
        system(.zoomWindow, "Zoom", .window, 0, nil, "performZoom:"),
        make(.recentTab, "Switch to Recent Tab", .window, 1, "ctrl+tab", synonyms: ["last tab", "previous tab"],
             symbol: "clock.arrow.circlepath", inBar: false, state: hasWindow) {
            $0.controller?.showRecentTabs(forward: true, commitWhenReleased: true)
        },
        make(.recentTabBack, "Switch to Recent Tab Backward", .window, 1, "ctrl+shift+tab", symbol: "clock.arrow.circlepath",
             inBar: false, state: hasWindow) {
            $0.controller?.showRecentTabs(forward: false, commitWhenReleased: true)
        },
        make(.nextTab, "Next Tab", .window, 1, "opt+cmd+down", symbol: "chevron.down.square", state: hasWindow) {
            $0.controller?.walkRail(step: 1)
        },
        make(.previousTab, "Previous Tab", .window, 1, "opt+cmd+up", symbol: "chevron.up.square", state: hasWindow) {
            $0.controller?.walkRail(step: -1)
        },
        make(.moveTabToNewWindow, "Move Tab to New Window", .window, 1, symbol: "macwindow.on.rectangle",
             state: { .when(!($0.controller?.tabs.isEmpty ?? true)) }) { $0.controller?.moveSelectedTabToNewWindow() },
        make(
            .mergeAllWindows, "Merge All Windows", .window, 1, symbol: "rectangle.stack",
            state: { context in
                guard let manager = context.manager else { return .disabled }
                return .when(manager.tabbedController.map { !manager.mergeSources(into: $0).isEmpty } ?? false)
            },
            run: { $0.manager?.mergeAllWindows() }
        ),
        tabCommand(.tab1, number: 1),
        tabCommand(.tab2, number: 2),
        tabCommand(.tab3, number: 3),
        tabCommand(.tab4, number: 4),
        tabCommand(.tab5, number: 5),
        tabCommand(.tab6, number: 6),
        tabCommand(.tab7, number: 7),
        tabCommand(.tab8, number: 8),
        tabCommand(.lastTab, number: 9),
        system(.bringAllToFront, "Bring All to Front", .window, 3, nil, "arrangeInFront:"),

        // Help
        make(.keyboardShortcuts, "Keyboard Shortcuts", .help, 0, synonyms: ["shortcuts", "keys", "remap"],
             symbol: "keyboard") { $0.manager?.showSettings(page: .shortcuts) },
    ]
}
