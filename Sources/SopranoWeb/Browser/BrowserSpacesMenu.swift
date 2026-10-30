import AppKit

/// The Spaces menu (stage 2's Bookmarks menu): every Space in display
/// order, the first nine on the registry's Switch to Space 1…9 shortcuts
/// (⌃1…⌃9 by default), the active window's current Space checked; the
/// registry's Next and Previous Space and its Spaces commands (Pin This
/// Page, Show Pinned Tabs, Archive Today Tabs); then every pin of the
/// active window's Space (Default's first Space without a window) as an
/// item that selects its live tab in the active window (or opens one
/// linked to it), every folder as a submenu
/// ending in Open All in Tabs. Rebuilt whenever the Spaces change and each
/// time the menu opens.
@MainActor
final class BrowserSpacesMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let titleLimit = 60
    /// The Spaces that get a Switch to Space shortcut.
    static let numberedSpaces = 9
    static let spaceCommands: [BrowserCommandID] = [
        .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9,
    ]

    let menu: NSMenu
    /// Next and Previous Space, and the menu's pin commands, put back on
    /// every rebuild.
    private let stepCommands: [NSMenuItem]
    private let commands: [NSMenuItem]
    private let windowManager: () -> BrowserWindowManager?
    private var observations: [BrowserObservation] = []
    /// The Space whose pins the menu lists (the active window's).
    private var shownSpaceID: UUID?
    /// The Space the menu checks (the active window's current one; none
    /// in a private or pop-up window).
    private var checkedSpaceID: UUID?

    init(
        menu: NSMenu,
        stepCommands: [NSMenuItem],
        commands: [NSMenuItem],
        windowManager: @escaping () -> BrowserWindowManager?
    ) {
        self.menu = menu
        self.stepCommands = stepCommands
        self.commands = commands
        self.windowManager = windowManager
        super.init()
        menu.delegate = self
        observeSpaces()
        rebuild()
    }

    /// Picks up a window manager that didn't exist when the menu was made,
    /// and the active window's Space when it changed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let needsObservation = observations.isEmpty
        observeSpaces()
        if needsObservation || currentSpaceID() != shownSpaceID
            || windowManager()?.tabbedController?.currentSpaceID != checkedSpaceID
        {
            rebuild()
        }
    }

    private func observeSpaces() {
        guard observations.isEmpty, let manager = windowManager() else { return }
        observations = [
            manager.spaces.changes.observe { [weak self] in self?.rebuild() },
            // A live folder's pull requests.
            manager.liveFolders.changes.observe { [weak self] in self?.rebuild() },
        ]
    }

    /// The window the menu's Space items switch: the active window with
    /// tabs, when it has Spaces.
    private func spaceWindow() -> BrowserWindowController? {
        windowManager()?.tabbedController.flatMap { $0.hasSpaces ? $0 : nil }
    }

    /// The active window's pin Space, else Default's first.
    private func currentSpaceID() -> UUID? {
        guard let manager = windowManager() else { return nil }
        return manager.tabbedController?.pinSpaceID
            ?? manager.spaces.space(ofProfile: BrowserProfile.defaultID)?.id
    }

    func rebuild() {
        menu.removeAllItems()
        shownSpaceID = currentSpaceID()
        let manager = windowManager()
        let checked = manager?.tabbedController?.currentSpaceID
        checkedSpaceID = checked
        let keymap = manager?.settingsStore.settings.keymap ?? BrowserKeymap()
        for (index, space) in (manager?.spaces.spaces ?? []).enumerated() {
            let item = NSMenuItem(title: Self.menuTitle(Self.spaceTitle(space)), action: #selector(switchSpace(_:)), keyEquivalent: "")
            if index < Self.numberedSpaces, let shortcut = keymap.shortcut(for: Self.spaceCommands[index]) {
                item.keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifierMask
            }
            item.target = self
            item.representedObject = space.id
            item.state = space.id == checked ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        stepCommands.forEach(menu.addItem)
        menu.addItem(.separator())
        commands.forEach(menu.addItem)
        guard let manager, let spaceID = shownSpaceID else { return }
        let tree = manager.liveFolders.display(manager.spaces.pinTree(inSpace: spaceID))
        guard !tree.isEmpty else { return }
        menu.addItem(.separator())
        add(tree.root.children, to: menu, favicons: manager.faviconStore)
    }

    /// A Space's menu title: its emoji (if it has one) and name.
    static func spaceTitle(_ space: BrowserSpace) -> String {
        if case let .emoji(emoji) = space.icon {
            return "\(emoji) \(space.displayName)"
        }
        return space.displayName
    }

    /// Space items work on a window with Spaces (not a private or pop-up
    /// one).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(switchSpace(_:)) ? spaceWindow() != nil : true
    }

    @objc private func switchSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let controller = spaceWindow() else { return }
        controller.switchToSpace(id)
        controller.revealWindowIfNeeded()
    }

    private func add(_ nodes: [BrowserPinNode], to menu: NSMenu, favicons: BrowserFaviconStore) {
        for node in nodes {
            switch node {
            case let .pin(pin):
                let item = NSMenuItem(
                    title: Self.menuTitle(pin.displayTitle),
                    action: #selector(openBookmark(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = pin.id
                item.toolTip = pin.url
                item.image = Self.menuImage(favicons.image(forAddress: pin.url))
                menu.addItem(item)
            case let .folder(folder):
                let item = NSMenuItem(title: Self.menuTitle(folder.displayName), action: nil, keyEquivalent: "")
                item.image = NSImage(
                    systemSymbolName: folder.isLive ? "arrow.triangle.pull" : "folder",
                    accessibilityDescription: folder.isLive ? "Live folder" : "Folder"
                )
                let submenu = NSMenu(title: folder.displayName)
                if folder.children.isEmpty {
                    let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    add(folder.children, to: submenu, favicons: favicons)
                }
                if !folder.allPins.isEmpty {
                    submenu.addItem(.separator())
                    let openAll = NSMenuItem(title: "Open All in Tabs", action: #selector(openFolder(_:)), keyEquivalent: "")
                    openAll.target = self
                    openAll.representedObject = folder.id
                    submenu.addItem(openAll)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    /// Selects the pin's live tab in the active window or opens one linked
    /// to it; a new window on its address when none is open.
    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let manager = windowManager() else { return }
        if let controller = manager.tabbedController {
            controller.openPin(id)
        } else if let url = sender.toolTip {
            _ = manager.newWindow(url: url)
        }
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let manager = windowManager() else { return }
        let controller = manager.tabbedController ?? manager.newWindow()
        controller.openBookmarkFolderInTabs(id)
    }

    static func menuTitle(_ title: String) -> String {
        title.count > titleLimit ? String(title.prefix(titleLimit - 1)) + "…" : title
    }

    private static func menuImage(_ favicon: NSImage?) -> NSImage? {
        guard let image = favicon?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// The menu as indented text, one item per line ("▸" marks a
    /// submenu, "✓" the checked item, "—" a separator); the harness prints
    /// it.
    static func dump(_ menu: NSMenu, depth: Int = 0) -> [String] {
        menu.items.flatMap { item -> [String] in
            let indent = String(repeating: "  ", count: depth + item.indentationLevel)
            if item.isSeparatorItem {
                return ["\(indent)—"]
            }
            var line = "\(indent)\(item.state == .on ? "✓ " : "")\(item.submenu == nil ? "" : "▸ ")\(item.title)"
            if !item.keyEquivalent.isEmpty {
                line += "  [\(shortcut(item))]"
            }
            if item.representedObject is UUID, let url = item.toolTip {
                // A pin: its address.
                line += "  <\(url)>"
            }
            if !item.isEnabled {
                line += "  (disabled)"
            }
            return [line] + (item.submenu.map { dump($0, depth: depth + 1) } ?? [])
        }
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key: String
        switch item.keyEquivalent.unicodeScalars.first.map({ Int($0.value) }) {
        case NSLeftArrowFunctionKey: key = "←"
        case NSRightArrowFunctionKey: key = "→"
        case NSUpArrowFunctionKey: key = "↑"
        case NSDownArrowFunctionKey: key = "↓"
        default: key = item.keyEquivalent.uppercased()
        }
        return text + key
    }
}
