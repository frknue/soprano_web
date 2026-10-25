import AppKit

@MainActor
final class MainMenuController: NSObject, NSMenuItemValidation {
    private let windowController: () -> BrowserWindowController?
    private var shareUpdater: ShareMenuUpdater?

    init(windowController: @escaping () -> BrowserWindowController?) {
        self.windowController = windowController
        super.init()
    }

    func install() {
        NSApp.mainMenu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
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
        let shareUpdater = ShareMenuUpdater { [windowController] in windowController()?.shareItems ?? [] }
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
        historyMenu.addItem(item("Show Bookmarks", #selector(showBookmarks), "b", [.command, .option]))
        historyMenu.addItem(item("Show Downloads", #selector(showDownloads), "l", [.command, .option]))
        historyMenu.addItem(.separator())
        historyMenu.addItem(item("Clear Browsing Data…", #selector(clearBrowsingData), "\u{8}", [.command, .shift]))
        add(historyMenu, to: main)

        let bookmarkMenu = NSMenu(title: "Bookmarks")
        bookmarkMenu.addItem(item("Bookmark This Page", #selector(bookmark), "d"))
        add(bookmarkMenu, to: main)

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
        guard let controller = windowController() else { return false }
        switch menuItem.action {
        case #selector(back):
            return controller.selectedTab?.webView.canGoBack ?? false
        case #selector(forward):
            return controller.selectedTab?.webView.canGoForward ?? false
        case #selector(closeTab):
            return !controller.tabs.isEmpty
        case #selector(reopenClosedTab):
            return controller.canReopenClosedTab
        case #selector(bookmark):
            return controller.selectedTab.map { !$0.isStartPage && $0.webView.url != nil } ?? false
        case #selector(printPage), #selector(exportPDF), #selector(saveAs):
            return controller.canUsePageTools
        case #selector(stop):
            return controller.isSelectedTabLoading
        default:
            return true
        }
    }

    private func controller() -> BrowserWindowController? {
        windowController()
    }

    @objc private func newTab() {
        controller()?.newTab(focusAddress: true)
        controller()?.revealWindowIfNeeded()
    }

    @objc private func openLocation() {
        controller()?.showWindowAndEnsureTab()
        controller()?.focusAddressBar()
    }

    @objc private func closeTab() {
        controller()?.closeSelectedTab()
    }

    @objc private func reopenClosedTab() {
        controller()?.reopenClosedTab()
        controller()?.revealWindowIfNeeded()
    }

    @objc private func closeWindow() {
        controller()?.window?.performClose(nil)
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
        controller()?.toggleBookmark()
    }

    @objc private func nextTab() {
        controller()?.selectNextTab()
    }

    @objc private func previousTab() {
        controller()?.selectPreviousTab()
    }

    @objc private func selectTabNumber(_ sender: NSMenuItem) {
        if sender.tag == 9 {
            controller()?.selectLastTab()
        } else {
            controller()?.selectTab(number: sender.tag)
        }
    }

    @objc private func openSettings() {
        controller()?.showSettings()
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
        ⇧⌘T Reopen closed tab  ⌃Tab / ⌃⇧Tab  Next / previous tab
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
