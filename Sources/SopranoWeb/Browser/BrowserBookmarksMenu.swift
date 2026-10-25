import AppKit

/// The Bookmarks menu below its own commands (Bookmark This Page, Show
/// Bookmarks): every pin of the active window's Space (Default's first
/// Space without a window) as an item that opens it in the active window,
/// every folder as a submenu ending in Open All in Tabs. Rebuilt whenever
/// the Spaces change and each time the menu opens.
@MainActor
final class BrowserBookmarksMenu: NSObject, NSMenuDelegate {
    static let titleLimit = 60

    let menu: NSMenu
    /// The menu's own commands, kept on every rebuild.
    private let commandCount: Int
    private let windowManager: () -> BrowserWindowManager?
    private var observation: BrowserObservation?
    /// The Space whose pins the menu lists.
    private var shownSpaceID: UUID?

    init(menu: NSMenu, windowManager: @escaping () -> BrowserWindowManager?) {
        self.menu = menu
        self.commandCount = menu.items.count
        self.windowManager = windowManager
        super.init()
        menu.delegate = self
        observeBookmarks()
        rebuild()
    }

    /// Picks up a window manager that didn't exist when the menu was made,
    /// and the active window's Space when it changed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let needsObservation = observation == nil
        observeBookmarks()
        if needsObservation || currentSpaceID() != shownSpaceID {
            rebuild()
        }
    }

    private func observeBookmarks() {
        guard observation == nil, let manager = windowManager() else { return }
        observation = manager.spaces.changes.observe { [weak self] in self?.rebuild() }
    }

    /// The active window's Space, else Default's first.
    private func currentSpaceID() -> UUID? {
        guard let manager = windowManager() else { return nil }
        return manager.tabbedController?.currentSpaceID
            ?? manager.spaces.firstSpace(ofProfile: BrowserProfile.defaultID)?.id
    }

    func rebuild() {
        while menu.items.count > commandCount {
            menu.removeItem(at: commandCount)
        }
        shownSpaceID = currentSpaceID()
        guard let manager = windowManager(), let spaceID = shownSpaceID else { return }
        let tree = manager.spaces.pinTree(inSpace: spaceID)
        guard !tree.isEmpty else { return }
        menu.addItem(.separator())
        add(tree.root.children, to: menu, favicons: manager.faviconStore)
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
                item.representedObject = pin.url
                item.toolTip = pin.url
                item.image = Self.menuImage(favicons.image(forAddress: pin.url))
                menu.addItem(item)
            case let .folder(folder):
                let item = NSMenuItem(title: Self.menuTitle(folder.displayName), action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
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

    /// Opens in the active window's tab, or a new window when none is open.
    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String, let manager = windowManager() else { return }
        if let controller = manager.tabbedController {
            controller.navigateCurrent(to: url)
        } else {
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
            if let url = item.representedObject as? String {
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
        return text + item.keyEquivalent.uppercased()
    }
}
