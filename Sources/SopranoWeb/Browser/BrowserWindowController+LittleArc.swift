import AppKit

/// A Little Arc's own controls: the "Open in" Spaces menu and ⌘O.
extension BrowserWindowController {
    /// ⌘O and the toolbar's button: the tab into its Space's window.
    func moveLittleArcToSpaceWindow() {
        manager.moveLittleArcToSpaceWindow(self)
    }

    /// "Open in": every Space, the Little Arc's own checked; another one
    /// moves it there (`BrowserWindowManager.moveLittleArc`).
    func openInMenu() -> NSMenu {
        let menu = NSMenu(title: "Open in")
        let header = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for space in spaces.spaces {
            let id = space.id
            let item = BrowserClosureMenuItem(title: BrowserSpacesMenu.spaceTitle(space)) { [weak self] in
                guard let self else { return }
                self.manager.moveLittleArc(self, toSpace: id)
            }
            item.state = id == littleSpaceID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let window = BrowserClosureMenuItem(title: "Space Window (⌘O)") { [weak self] in
            self?.moveLittleArcToSpaceWindow()
        }
        menu.addItem(window)
        return menu
    }

    func showOpenInMenu(from anchor: NSView) {
        guard role == .little else { return }
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        openInMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
    }
}
