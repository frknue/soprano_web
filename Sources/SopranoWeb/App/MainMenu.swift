import AppKit

@MainActor
final class MainMenuController: NSObject, NSMenuItemValidation {
    static let newWindowWithProfileTitle = "New Window With Profile"

    private let windowManager: () -> BrowserWindowManager?
    private var shareUpdater: ShareMenuUpdater?
    private var recentlyClosedUpdater: RecentlyClosedMenuUpdater?
    private var profileWindowUpdater: ProfileWindowMenuUpdater?
    private(set) var spacesMenu: BrowserSpacesMenu?
    /// File ▸ New Window With Profile, shown while more than one profile
    /// exists.
    private var profileWindowItem: NSMenuItem?
    private var profilesObservation: BrowserObservation?

    init(windowManager: @escaping () -> BrowserWindowManager?) {
        self.windowManager = windowManager
        super.init()
    }

    func install() {
        NSApp.mainMenu = buildMenu()
        profilesObservation = windowManager()?.profiles.changes.observe { [weak self] in
            self?.refreshProfileWindowItem()
        }
        refreshProfileWindowItem()
    }

    private func refreshProfileWindowItem() {
        profileWindowItem?.isHidden = !(windowManager()?.profiles.hasSeveral ?? false)
    }

    /// The main menu; `install` makes it the app's (the harness only reads
    /// it).
    func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Soprano Web")
        appMenu.addItem(
            withTitle: "About Soprano Web",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), "comma"))
        appMenu.addItem(.separator())
        appMenu.addItem(StandardMenus.services())
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Soprano Web",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Soprano Web",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        add(appMenu, to: main)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Tab", #selector(newTab), "t"))
        fileMenu.addItem(item("New Window", #selector(newWindow), "n"))
        fileMenu.addItem(item("New Private Window", #selector(newPrivateWindow), "n", [.command, .shift]))
        let profileMenu = NSMenu(title: Self.newWindowWithProfileTitle)
        let profileWindowUpdater = ProfileWindowMenuUpdater(windowManager: windowManager)
        profileMenu.delegate = profileWindowUpdater
        self.profileWindowUpdater = profileWindowUpdater
        let profileWindowItem = NSMenuItem(title: profileMenu.title, action: nil, keyEquivalent: "")
        profileWindowItem.submenu = profileMenu
        self.profileWindowItem = profileWindowItem
        fileMenu.addItem(profileWindowItem)
        fileMenu.addItem(item("Reopen Closed Tab", #selector(reopenClosedTab), "t", [.command, .shift]))
        fileMenu.addItem(item("Open Location…", #selector(openLocation), "l"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", #selector(closeTab), "w"))
        fileMenu.addItem(item("Close Window", #selector(closeWindow), "w", [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Save As…", #selector(saveAs), "s", [.command, .shift]))
        fileMenu.addItem(item("Export as PDF…", #selector(exportPDF), ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(ShareMenuUpdater.placeholder())
        let shareUpdater = ShareMenuUpdater { [windowManager] in windowManager()?.activeController?.shareItems ?? [] }
        self.shareUpdater = shareUpdater
        fileMenu.delegate = shareUpdater
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Print…", #selector(printPage), "p"))
        add(fileMenu, to: main)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find…", #selector(find), "f"))
        editMenu.addItem(item("Find Next", #selector(findNext), "g"))
        editMenu.addItem(item("Find Previous", #selector(findPrevious), "g", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(StandardMenus.spellingAndGrammar())
        editMenu.addItem(StandardMenus.substitutions())
        editMenu.addItem(StandardMenus.transformations())
        editMenu.addItem(StandardMenus.speech())
        add(editMenu, to: main)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Command Palette…", #selector(showPalette), "p", [.command, .shift]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Back", #selector(back), "["))
        viewMenu.addItem(item("Forward", #selector(forward), "]"))
        viewMenu.addItem(item("Home", #selector(home), "h", [.command, .shift]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Reload", #selector(reload), "r"))
        viewMenu.addItem(item("Stop", #selector(stop), "."))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom In", #selector(zoomIn), "="))
        viewMenu.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        viewMenu.addItem(item("Actual Size", #selector(resetZoom), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Toggle Sidebar", #selector(toggleSidebar), "b", [.command, .shift]))
        viewMenu.addItem(item("Toggle Vertical Sidebar", #selector(toggleVerticalSidebar), "s"))
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(viewMenu, to: main)

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(item("Show All History", #selector(showHistory), "y"))
        historyMenu.addItem(item("Show Downloads", #selector(showDownloads), "l", [.command, .option]))
        historyMenu.addItem(.separator())
        let recentlyClosed = NSMenu(title: "Recently Closed")
        let recentlyClosedUpdater = RecentlyClosedMenuUpdater(windowManager: windowManager)
        recentlyClosed.delegate = recentlyClosedUpdater
        self.recentlyClosedUpdater = recentlyClosedUpdater
        let recentlyClosedItem = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        recentlyClosedItem.submenu = recentlyClosed
        historyMenu.addItem(recentlyClosedItem)
        historyMenu.addItem(.separator())
        historyMenu.addItem(item("Clear Browsing Data…", #selector(clearBrowsingData), "\u{8}", [.command, .shift]))
        add(historyMenu, to: main)

        let spacesMenu = NSMenu(title: "Spaces")
        self.spacesMenu = BrowserSpacesMenu(
            menu: spacesMenu,
            commands: [
                item("Bookmark This Page", #selector(bookmark), "d"),
                item("Show Bookmarks", #selector(showBookmarks), "b", [.command, .option]),
            ],
            windowManager: windowManager
        )
        add(spacesMenu, to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Next Tab", #selector(nextTab), "\t", [.control]))
        windowMenu.addItem(item("Previous Tab", #selector(previousTab), "\t", [.control, .shift]))
        windowMenu.addItem(item("Move Tab to New Window", #selector(moveTabToNewWindow), ""))
        windowMenu.addItem(item("Merge All Windows", #selector(mergeAllWindows), ""))
        windowMenu.addItem(.separator())
        for number in 1...9 {
            let title = number == 9 ? "Last Tab" : "Tab \(number)"
            let select = item(title, #selector(selectTabNumber(_:)), "\(number)")
            select.tag = number
            windowMenu.addItem(select)
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Keyboard Shortcuts", #selector(showShortcuts), ""))
        add(helpMenu, to: main)
        NSApp.helpMenu = helpMenu

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    private func item(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if key != "\t" {
            item.keyEquivalentModifierMask = modifiers
        } else {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let manager = windowManager() else { return false }
        switch menuItem.action {
        case #selector(newWindow), #selector(newPrivateWindow), #selector(newTab), #selector(openLocation),
             #selector(openSettings):
            return true
        case #selector(reopenClosedTab):
            // A private window reopens only its own closed tabs.
            if let controller = manager.activeController, !controller.kind.usesAppRecentlyClosed {
                menuItem.title = "Reopen Closed Tab"
                return controller.canReopenClosedTab
            }
            menuItem.title = manager.recentlyClosed.newest?.isWindow == true
                ? "Reopen Closed Window"
                : "Reopen Closed Tab"
            return !manager.recentlyClosed.isEmpty
        case #selector(closeWindow):
            return NSApp.keyWindow != nil || manager.activeController != nil
        default:
            break
        }
        guard let controller = manager.activeController else { return false }
        switch menuItem.action {
        case #selector(back):
            return controller.selectedTab?.webView.canGoBack ?? false
        case #selector(forward):
            return controller.selectedTab?.webView.canGoForward ?? false
        case #selector(closeTab), #selector(moveTabToNewWindow):
            return !controller.tabs.isEmpty
        case #selector(mergeAllWindows):
            return manager.tabbedController.map { !manager.mergeSources(into: $0).isEmpty } ?? false
        case #selector(bookmark):
            guard let tab = controller.selectedTab, !tab.isStartPage, let url = tab.webView.url else { return false }
            let isPinned = controller.pinSpaceID.map {
                controller.spaces.isPinned(url.absoluteString, inSpace: $0)
            } ?? false
            menuItem.title = isPinned ? "Edit Bookmark" : "Bookmark This Page"
            return true
        case #selector(printPage), #selector(exportPDF), #selector(saveAs):
            return controller.canUsePageTools
        case #selector(stop):
            return controller.isSelectedTabLoading
        default:
            return true
        }
    }

    /// The window menu commands act on: the key browser window, else the
    /// most recently active one.
    private func controller() -> BrowserWindowController? {
        windowManager()?.activeController
    }

    @objc private func newTab() {
        guard let controller = controller() else {
            windowManager()?.newWindow()
            return
        }
        controller.newTab(focusAddress: true)
        controller.revealWindowIfNeeded()
    }

    @objc private func newWindow() {
        windowManager()?.newWindow()
    }

    @objc private func newPrivateWindow() {
        windowManager()?.newPrivateWindow()
    }

    @objc private func openLocation() {
        guard let manager = windowManager() else { return }
        guard let controller = manager.activeController else {
            manager.newWindow()
            return
        }
        manager.present(controller)
        controller.focusAddressBar()
    }

    @objc private func closeTab() {
        controller()?.closeSelectedTab()
    }

    /// ⇧⌘T: in a private window its own last closed tab, otherwise the
    /// newest entry of the app-wide stack.
    @objc private func reopenClosedTab() {
        guard let manager = windowManager() else { return }
        if let controller = manager.activeController {
            controller.reopenClosedTab()
        } else {
            manager.reopenMostRecent()
        }
    }

    /// ⇧⌘W closes the key window: a browser window onto the recently-closed
    /// stack, any other window (Settings) the usual way.
    @objc private func closeWindow() {
        guard let manager = windowManager() else { return }
        if let key = NSApp.keyWindow, !manager.controllers.contains(where: { $0.window === key }) {
            key.performClose(nil)
        } else if let controller = manager.activeController {
            manager.closeWindow(controller)
        }
    }

    @objc private func back() {
        controller()?.goBack()
    }

    @objc private func forward() {
        controller()?.goForward()
    }

    @objc private func reload() {
        controller()?.reloadOrStop()
    }

    @objc private func stop() {
        controller()?.stopLoading()
    }

    @objc private func home() {
        controller()?.goHome()
    }

    @objc private func find() {
        controller()?.showFindBar()
    }

    @objc private func findNext() {
        controller()?.findNext()
    }

    @objc private func findPrevious() {
        controller()?.findPrevious()
    }

    @objc private func zoomIn() {
        controller()?.zoomIn()
    }

    @objc private func zoomOut() {
        controller()?.zoomOut()
    }

    @objc private func resetZoom() {
        controller()?.resetZoom()
    }

    @objc private func toggleSidebar() {
        controller()?.toggleSidebar()
    }

    @objc private func toggleVerticalSidebar() {
        controller()?.toggleVerticalSidebar()
    }

    @objc private func showHistory() {
        controller()?.showSidebar(section: .history)
    }

    @objc private func showBookmarks() {
        controller()?.showSidebar(section: .bookmarks)
    }

    @objc private func showDownloads() {
        controller()?.showSidebar(section: .downloads)
    }

    @objc private func clearBrowsingData() {
        controller()?.showClearBrowsingData()
    }

    @objc private func bookmark() {
        controller()?.bookmarkCurrentPage()
    }

    @objc private func nextTab() {
        controller()?.selectNextTab()
    }

    @objc private func previousTab() {
        controller()?.selectPreviousTab()
    }

    @objc private func moveTabToNewWindow() {
        controller()?.moveSelectedTabToNewWindow()
    }

    @objc private func mergeAllWindows() {
        windowManager()?.mergeAllWindows()
    }

    @objc private func selectTabNumber(_ sender: NSMenuItem) {
        if sender.tag == 9 {
            controller()?.selectLastTab()
        } else {
            controller()?.selectTab(number: sender.tag)
        }
    }

    @objc private func openSettings() {
        windowManager()?.showSettings()
    }

    @objc private func showPalette() {
        controller()?.showCommandPalette()
    }

    @objc private func printPage() {
        controller()?.printSelectedPage()
    }

    @objc private func exportPDF() {
        controller()?.exportSelectedPageAsPDF()
    }

    @objc private func saveAs() {
        controller()?.saveSelectedPageAs()
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Soprano Web Shortcuts"
        alert.informativeText = """
        ⌘L  Address bar
        ⌘T  New tab            ⌘W  Close tab
        ⌘N  New window         ⇧⌘N New private window
        ⇧⌘W Close window
        ⇧⌘T Reopen closed tab or window
        ⌃Tab / ⌃⇧Tab  Next / previous tab
        ⌃1–⌃9 Space by number
        ⌥⌘→ / ⌥⌘←  Next / previous Space
        ⌘[  Back               ⌘]  Forward
        ⌘R  Reload             ⌘F  Find in page
        ⌘D  Bookmark           ⌘Y  History
        ⌥⌘B Bookmarks          ⌥⌘L Downloads
        ⌘= / ⌘- / ⌘0  Zoom in / out / reset
        ⌘P  Print              ⇧⌘S Save as
        ⇧⌘P Command palette    ⌘.  Stop loading
        ⇧⌘B Right sidebar      ⌘S  Vertical sidebar
        ⌘1–⌘8 Tab by number    ⌘9  Last tab
        ⇧⌘⌫ Clear browsing data
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Fills History ▸ Recently Closed each time it opens: closed tabs and
/// windows, newest first.
@MainActor
private final class RecentlyClosedMenuUpdater: NSObject, NSMenuDelegate {
    private let windowManager: () -> BrowserWindowManager?

    init(windowManager: @escaping () -> BrowserWindowManager?) {
        self.windowManager = windowManager
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = windowManager()?.recentlyClosed.newestFirst ?? []
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "Nothing Recently Closed", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(reopen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.image = NSImage(
                systemSymbolName: entry.isWindow ? "macwindow" : "doc",
                accessibilityDescription: entry.isWindow ? "Window" : "Tab"
            )
            menu.addItem(item)
        }
    }

    @objc private func reopen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windowManager()?.reopen(entryID: id)
    }
}

/// Fills File ▸ New Window With Profile each time it opens: one item per
/// profile.
@MainActor
private final class ProfileWindowMenuUpdater: NSObject, NSMenuDelegate {
    private let windowManager: () -> BrowserWindowManager?

    init(windowManager: @escaping () -> BrowserWindowManager?) {
        self.windowManager = windowManager
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for profile in windowManager()?.profiles.profiles ?? [] {
            let item = NSMenuItem(title: profile.name, action: #selector(newWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
    }

    @objc private func newWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windowManager()?.newWindow(profileID: id)
    }
}
