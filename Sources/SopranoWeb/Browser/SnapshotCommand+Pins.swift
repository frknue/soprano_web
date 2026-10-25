import AppKit

/// Snapshot flags for Spaces and their pinned folders. Results print as
/// `space…:` / `pin…:` lines; the ⌘D popover is built and captured
/// offscreen, never shown. Every flag works on the window's current Space
/// (`BrowserWindowController.currentSpaceID`).
extension SnapshotCommand {
    struct PinOptions {
        /// `--bookmarks-file <json>`: copied in as stage 2's
        /// `bookmarks.json` before the Space store opens (version 1 or 2;
        /// it becomes Default's Space's pins).
        var file: String?
        /// `--pins-tree`: seeds nested folders into Default's Space before
        /// the first window (also seeded into the window's Space by any
        /// `--sidebar` when it has no pins).
        var seedTree = false
        /// `--expand-folder <name|all>` (repeatable).
        var expand: [String] = []
        /// `--pin-search <text>`: typed into the sidebar's search.
        var search: String?
        /// `--pin-drop <title>:on|above:<row>` (repeatable): the outline's
        /// drop handler, rows as `--print-pins` numbers them.
        var drops: [(title: String, drop: BrowserPinOutline.Drop)] = []
        /// `--pin-folder <name>`: ⌘D's last-used folder in the Space.
        var lastFolder: String?
        /// `--pin-popover`: ⌘D on the selected page, popover captured.
        var popover = false
        /// `--print-pins`: the Spaces, the current Space's tree, the
        /// outline rows, Vimium's lines, the file and the Bookmarks menu.
        var print = false

        var isActive: Bool {
            seedTree || !expand.isEmpty || search != nil || !drops.isEmpty || lastFolder != nil || popover || print
        }
    }

    static let pinsUsage = """
                                   [--bookmarks-file <json>] [--pins-tree] [--expand-folder <name|all>]...
                                   [--pin-search <text>] [--pin-drop <title>:on|above:<row>]...
                                   [--pin-folder <name>] [--pin-popover] [--print-pins]
    """

    /// Parses `option` if it is a pin flag; false means not ours.
    nonisolated static func parsePins(
        _ option: String,
        value: () throws -> String,
        into options: inout PinOptions
    ) throws -> Bool {
        switch option {
        case "--bookmarks-file":
            options.file = try value()
        case "--pins-tree":
            options.seedTree = true
        case "--expand-folder":
            options.expand.append(try value())
        case "--pin-search":
            options.search = try value()
        case "--pin-drop":
            let text = try value()
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let row = Int(parts[parts.count - 1]) else {
                throw OptionError.unknownOption("\(option) \(text)")
            }
            let title = parts.dropLast(2).joined(separator: ":")
            switch parts[parts.count - 2] {
            case "on": options.drops.append((title, .on(row)))
            case "above": options.drops.append((title, .above(row)))
            default: throw OptionError.unknownOption("\(option) \(text)")
            }
        case "--pin-folder":
            options.lastFolder = try value()
        case "--pin-popover":
            options.popover = true
        case "--print-pins":
            options.print = true
        default:
            return false
        }
        return true
    }

    /// Before the Space store opens: `--bookmarks-file`.
    static func prepareBookmarksFile(_ options: PinOptions, at url: URL) {
        guard let file = options.file else { return }
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: url)
    }

    /// Nested folders, one empty, and two top-level pins, in Space
    /// `spaceID` while it has none.
    static func seedPinTree(_ store: BrowserSpaceStore, inSpace spaceID: UUID?) {
        guard let spaceID, store.pinTree(inSpace: spaceID).isEmpty else { return }
        func pin(_ title: String, _ url: String) -> BrowserPinNode {
            .pin(BrowserPin(url: url, title: title))
        }
        store.insert(.folder(BrowserPinFolder(name: "Work", children: [
            pin("Soprano Web", "https://github.com/frknue/soprano_web"),
            .folder(BrowserPinFolder(name: "Docs", children: [
                pin("WebKit Documentation", "https://developer.apple.com/documentation/webkit"),
                pin("The Swift Programming Language", "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/"),
            ])),
            pin("Pull requests", "https://github.com/frknue/soprano_web/pulls"),
        ])), inSpace: spaceID)
        store.insert(.folder(BrowserPinFolder(name: "Reading", children: [
            pin("WebKit Blog", "https://webkit.org/blog/"),
            pin("Hacker News", "https://news.ycombinator.com/"),
        ])), inSpace: spaceID)
        store.insert(pin("WebKit", "https://webkit.org/"), inSpace: spaceID)
        store.insert(pin("Swift", "https://www.swift.org/"), inSpace: spaceID)
        store.insert(.folder(BrowserPinFolder(name: "Later")), inSpace: spaceID)
    }

    /// After the sidebar opens: expand, search and drop, then print.
    static func runPinScenario(_ options: PinOptions, controller: BrowserWindowController) {
        let store = controller.spaces
        let sidebar = controller.sidebar
        for name in options.expand {
            let folders = controller.currentPinTree.folderEntries().filter {
                $0.id != BrowserPinTree.rootID && (name == "all" || $0.name == name)
            }
            for folder in folders {
                sidebar.setFolderExpanded(folder.id, true)
            }
        }
        if let name = options.lastFolder, let spaceID = controller.currentSpaceID {
            let folder = controller.currentPinTree.folderEntries().first { $0.name == name }
            controller.manager.pinUIState.setLastFolderID(folder?.id, inSpace: spaceID)
        }
        for (title, drop) in options.drops {
            guard let node = sidebar.outlineRows.first(where: { $0.node.title == title })?.node else {
                print("pin-drop: no visible row titled \(title)")
                continue
            }
            let destination = sidebar.bookmarkDestination(for: node.id, drop: drop)
            let moved = sidebar.performBookmarkDrop(node.id, drop: drop)
            let target = destination.flatMap { controller.currentPinTree.folder(id: $0.folderID)?.displayName } ?? "-"
            print("pin-drop: \(title) \(drop) -> \(moved ? "moved into \(target) at \(destination?.index ?? -1)" : "refused")")
        }
        if let search = options.search, let spaceID = controller.currentSpaceID {
            sidebar.setSearchText(search)
            for entry in store.matchingPins(search, inSpace: spaceID) {
                print("pin-search: \(entry.pin.displayTitle) — \(entry.pathText)")
            }
        }
        if options.print {
            printPins(controller)
        }
    }

    static func printPins(_ controller: BrowserWindowController) {
        let store = controller.spaces
        let profiles = controller.manager.profiles
        for space in store.spaces {
            let icon = switch space.icon {
            case .none: "none"
            case let .emoji(value): "emoji \(value)"
            case let .symbol(value): "symbol \(value)"
            }
            let profile = profiles.profile(id: space.profileID)?.name ?? space.profileID.uuidString
            let current = space.id == controller.currentSpaceID ? " (current)" : ""
            print("space: \(space.displayName)\(current) | profile \(profile) | color \(space.color.rawValue) | icon \(icon) | \(store.pinEntries(inSpace: space.id).count) pins")
        }
        for profile in profiles.profiles {
            let favorites = store.favorites(ofProfile: profile.id)
            print("favorites: \(profile.name) \(favorites.count)/\(BrowserFavorites.limit) | archive \(profile.archiveAfter.rawValue)")
        }
        func walk(_ folder: BrowserPinFolder, depth: Int) {
            for node in folder.children {
                let indent = String(repeating: "  ", count: depth)
                switch node {
                case let .pin(pin):
                    print("pin-tree: \(indent)\(pin.displayTitle) <\(pin.url)>")
                case let .folder(child):
                    print("pin-tree: \(indent)\(child.displayName)/")
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(controller.currentPinTree.root, depth: 0)
        for (index, row) in controller.sidebar.outlineRows.enumerated() {
            let mark = row.node.isFolder ? (row.isExpanded ? "▾ " : "▸ ") : "  "
            print("pin-outline: \(index) \(String(repeating: "  ", count: row.depth))\(mark)\(row.node.title)")
        }
        for entry in controller.currentSpaceID.map({ store.pinEntries(inSpace: $0) }) ?? [] {
            print("pin-vimium: \(entry.pin.displayTitle) | \(entry.detail)")
        }
        let file = (try? Data(contentsOf: store.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let fileSpaces = (file?["spaces"] as? [Any])?.count ?? 0
        let migrated = FileManager.default.fileExists(atPath: store.migratedBookmarksURL.path) ? "kept" : "none"
        print("spaces-file: version \(file?["version"] as? Int ?? 0), \(fileSpaces) spaces, bookmarks.json migrated copy \(migrated)")
        let menuController = MainMenuController { [manager = controller.manager] in manager }
        let main = menuController.buildMenu()
        if let menu = main.item(withTitle: "Bookmarks")?.submenu {
            for line in BrowserBookmarksMenu.dump(menu) {
                print("bookmarks-menu: \(line)")
            }
        }
    }

    /// ⌘D on the selected page through the same path the menu takes,
    /// except the editor goes into the window offscreen instead of a
    /// panel. Returns it for the capture to draw over the page.
    static func makePinPopover(_ options: PinOptions, controller: BrowserWindowController) -> NSView? {
        guard options.popover else { return nil }
        guard let result = controller.bookmarkSelectedPage(),
              let editor = controller.makeBookmarkEditor(
                  for: result.pin.id,
                  heading: result.added ? "Bookmark Added" : "Edit Bookmark",
                  showsURL: false
              )
        else {
            print("pin-popover: nothing to pin on this tab")
            return nil
        }
        let root = controller.rootView
        editor.translatesAutoresizingMaskIntoConstraints = true
        editor.layoutSubtreeIfNeeded()
        let anchor = controller.toolbar.bookmarkAnchor
        let anchorRect = anchor.convert(anchor.bounds, to: root)
        editor.frame = BrowserPinEditorView.frame(size: editor.fittingSize, below: anchorRect, within: root.bounds)
        root.addSubview(editor, positioned: .above, relativeTo: nil)
        editor.layoutSubtreeIfNeeded()
        let folder = controller.currentPinTree.folder(id: editor.content.folderID)?.displayName ?? "?"
        let pinned = controller.currentSpaceID.map { controller.spaces.isPinned(result.pin.url, inSpace: $0) } ?? false
        print("pin-popover: \(editor.content.heading) | name \(editor.nameField.stringValue) | folder \(folder) | star \(pinned ? "filled" : "empty")")
        for line in BrowserBookmarksMenu.dump(editor.folderMenu()) {
            print("pin-popover-folders: \(line)")
        }
        return editor
    }
}
