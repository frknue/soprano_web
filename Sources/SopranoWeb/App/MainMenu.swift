import AppKit

/// The menu bar, built from the command registry (`BrowserAppCommand.all`):
/// every item's title, shortcut (the user's keymap), validation and action
/// come from its registry row; the menus add only their dynamic parts
/// (New Window With Profile, Share, Recently Closed, the Spaces and their
/// pins, the system's Edit submenus and Services).
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
    private var observations: [BrowserObservation] = []
    private var shownKeymap: BrowserKeymap?

    init(windowManager: @escaping () -> BrowserWindowManager?) {
        self.windowManager = windowManager
        super.init()
    }

    func install() {
        NSApp.mainMenu = buildMenu()
        if let manager = windowManager() {
            observations = [
                manager.profiles.changes.observe { [weak self] in self?.refreshProfileWindowItem() },
                // Settings ▸ Keyboard shortcuts: the items follow a remap.
                manager.settingsStore.changes.observe { [weak self] _ in self?.applyKeymap() },
            ]
        }
        refreshProfileWindowItem()
    }

    private func refreshProfileWindowItem() {
        profileWindowItem?.isHidden = !(windowManager()?.profiles.hasSeveral ?? false)
    }

    private var keymap: BrowserKeymap {
        windowManager()?.settingsStore.settings.keymap ?? BrowserKeymap()
    }

    /// The main menu; `install` makes it the app's (the harness only reads
    /// it).
    func buildMenu() -> NSMenu {
        let main = NSMenu()
        let keymap = keymap
        shownKeymap = keymap

        let appMenu = NSMenu(title: BrowserAppCommand.Menu.app.rawValue)
        addSections([0, 1], of: .app, to: appMenu, keymap: keymap)
        appMenu.addItem(.separator())
        appMenu.addItem(StandardMenus.services())
        appMenu.addItem(.separator())
        addSections([2, 3], of: .app, to: appMenu, keymap: keymap)
        add(appMenu, to: main)

        let fileMenu = NSMenu(title: BrowserAppCommand.Menu.file.rawValue)
        addSections([0], of: .file, to: fileMenu, keymap: keymap)
        let profileMenu = NSMenu(title: Self.newWindowWithProfileTitle)
        let profileWindowUpdater = ProfileWindowMenuUpdater(windowManager: windowManager)
        profileMenu.delegate = profileWindowUpdater
        self.profileWindowUpdater = profileWindowUpdater
        let profileWindowItem = NSMenuItem(title: profileMenu.title, action: nil, keyEquivalent: "")
        profileWindowItem.submenu = profileMenu
        self.profileWindowItem = profileWindowItem
        fileMenu.addItem(profileWindowItem)
        // Reopen Closed Tab and Open Location… follow without a separator.
        commands(of: .file, section: 1).forEach { fileMenu.addItem(item(for: $0, keymap: keymap)) }
        fileMenu.addItem(.separator())
        addSections([2, 3, 5], of: .file, to: fileMenu, keymap: keymap)
        fileMenu.addItem(.separator())
        fileMenu.addItem(ShareMenuUpdater.placeholder())
        let shareUpdater = ShareMenuUpdater { [windowManager] in windowManager()?.activeController?.shareItems ?? [] }
        self.shareUpdater = shareUpdater
        fileMenu.delegate = shareUpdater
        fileMenu.addItem(.separator())
        addSections([4], of: .file, to: fileMenu, keymap: keymap)
        add(fileMenu, to: main)

        let editMenu = NSMenu(title: BrowserAppCommand.Menu.edit.rawValue)
        addSections([0, 1, 2, 3], of: .edit, to: editMenu, keymap: keymap)
        editMenu.addItem(.separator())
        editMenu.addItem(StandardMenus.spellingAndGrammar())
        editMenu.addItem(StandardMenus.substitutions())
        editMenu.addItem(StandardMenus.transformations())
        editMenu.addItem(StandardMenus.speech())
        add(editMenu, to: main)

        let viewMenu = NSMenu(title: BrowserAppCommand.Menu.view.rawValue)
        addSections([0, 1, 2, 3, 4, 5], of: .view, to: viewMenu, keymap: keymap)
        add(viewMenu, to: main)

        let historyMenu = NSMenu(title: BrowserAppCommand.Menu.history.rawValue)
        addSections([0], of: .history, to: historyMenu, keymap: keymap)
        historyMenu.addItem(.separator())
        let recentlyClosed = NSMenu(title: "Recently Closed")
        let recentlyClosedUpdater = RecentlyClosedMenuUpdater(windowManager: windowManager)
        recentlyClosed.delegate = recentlyClosedUpdater
        self.recentlyClosedUpdater = recentlyClosedUpdater
        let recentlyClosedItem = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        recentlyClosedItem.submenu = recentlyClosed
        historyMenu.addItem(recentlyClosedItem)
        historyMenu.addItem(.separator())
        addSections([1], of: .history, to: historyMenu, keymap: keymap)
        add(historyMenu, to: main)

        let spacesMenu = NSMenu(title: BrowserAppCommand.Menu.spaces.rawValue)
        self.spacesMenu = BrowserSpacesMenu(
            menu: spacesMenu,
            stepCommands: commands(of: .spaces, section: 1).map { item(for: $0, keymap: keymap) },
            commands: commands(of: .spaces, section: 2).map { item(for: $0, keymap: keymap) },
            windowManager: windowManager
        )
        add(spacesMenu, to: main)

        let windowMenu = NSMenu(title: BrowserAppCommand.Menu.window.rawValue)
        addSections([0, 1, 2, 3], of: .window, to: windowMenu, keymap: keymap)
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: BrowserAppCommand.Menu.help.rawValue)
        addSections([0], of: .help, to: helpMenu, keymap: keymap)
        add(helpMenu, to: main)
        NSApp.helpMenu = helpMenu

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    private func commands(of menu: BrowserAppCommand.Menu, section: Int) -> [BrowserAppCommand] {
        BrowserAppCommand.all.filter { $0.menu == menu && $0.section == section && $0.hasMenuItem }
    }

    /// The registry's items of `sections`, a separator between sections.
    private func addSections(_ sections: [Int], of menu: BrowserAppCommand.Menu, to target: NSMenu, keymap: BrowserKeymap) {
        for section in sections {
            let items = commands(of: menu, section: section)
            guard !items.isEmpty else { continue }
            if let last = target.items.last, !last.isSeparatorItem {
                target.addItem(.separator())
            }
            items.forEach { target.addItem(item(for: $0, keymap: keymap)) }
        }
    }

    /// A registry command's item: identifier = the command id; a system
    /// command sends its standard action down the responder chain, every
    /// other one runs through `runCommand(_:)`.
    private func item(for command: BrowserAppCommand, keymap: BrowserKeymap) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(command.id.rawValue)
        if let action = command.systemAction {
            item.action = NSSelectorFromString(action)
        } else {
            item.action = #selector(runCommand(_:))
            item.target = self
        }
        Self.apply(keymap.shortcut(for: command.id), to: item)
        return item
    }

    private static func apply(_ shortcut: BrowserShortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.keyEquivalent ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifierMask ?? []
    }

    /// Re-applies the keymap to every registry item after Settings ▸
    /// Keyboard shortcuts changed it.
    private func applyKeymap() {
        let keymap = keymap
        guard keymap != shownKeymap, let main = NSApp.mainMenu else { return }
        shownKeymap = keymap
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let raw = item.identifier?.rawValue, let id = BrowserCommandID(rawValue: raw) {
                    Self.apply(keymap.shortcut(for: id), to: item)
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(main)
        spacesMenu?.rebuild()
    }

    private func command(of item: NSMenuItem) -> BrowserAppCommand? {
        item.identifier.flatMap { BrowserCommandID(rawValue: $0.rawValue) }?.command
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = command(of: menuItem) else { return true }
        guard let manager = windowManager() else { return false }
        let state = command.state(BrowserCommandContext(manager: manager))
        if let title = state.title {
            menuItem.title = title
        }
        return state.isEnabled
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = command(of: sender), let manager = windowManager() else { return }
        command.perform(in: BrowserCommandContext(manager: manager))
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
