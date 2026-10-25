import AppKit

/// Snapshot flags for bookmark folders. Results print as `bookmark…:`
/// lines; the ⌘D popover is built and captured offscreen, never shown.
extension SnapshotCommand {
    struct BookmarkOptions {
        /// `--bookmarks-file <json>`: copied in as `bookmarks.json` before
        /// the store opens (a version 1 file migrates).
        var file: String?
        /// `--bookmarks-tree`: seeds nested folders (also seeded by any
        /// `--sidebar` when there are no bookmarks).
        var seedTree = false
        /// `--expand-folder <name|all>` (repeatable).
        var expand: [String] = []
        /// `--bookmark-search <text>`: typed into the sidebar's search.
        var search: String?
        /// `--bookmark-drop <title>:on|above:<row>` (repeatable): the
        /// outline's drop handler, rows as `--print-bookmarks` numbers them.
        var drops: [(title: String, drop: BrowserBookmarkOutline.Drop)] = []
        /// `--bookmark-folder <name>`: ⌘D's last-used folder.
        var lastFolder: String?
        /// `--bookmark-popover`: ⌘D on the selected page, popover captured.
        var popover = false
        /// `--print-bookmarks`: the tree, the outline rows, Vimium's lines
        /// and the Bookmarks menu.
        var print = false

        var isActive: Bool {
            seedTree || !expand.isEmpty || search != nil || !drops.isEmpty || lastFolder != nil || popover || print
        }
    }

    static let bookmarksUsage = """
                                   [--bookmarks-file <json>] [--bookmarks-tree] [--expand-folder <name|all>]...
                                   [--bookmark-search <text>] [--bookmark-drop <title>:on|above:<row>]...
                                   [--bookmark-folder <name>] [--bookmark-popover] [--print-bookmarks]
    """

    /// Parses `option` if it is a bookmark flag; false means not ours.
    nonisolated static func parseBookmarks(
        _ option: String,
        value: () throws -> String,
        into options: inout BookmarkOptions
    ) throws -> Bool {
        switch option {
        case "--bookmarks-file":
            options.file = try value()
        case "--bookmarks-tree":
            options.seedTree = true
        case "--expand-folder":
            options.expand.append(try value())
        case "--bookmark-search":
            options.search = try value()
        case "--bookmark-drop":
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
        case "--bookmark-folder":
            options.lastFolder = try value()
        case "--bookmark-popover":
            options.popover = true
        case "--print-bookmarks":
            options.print = true
        default:
            return false
        }
        return true
    }

    /// Before the store opens: `--bookmarks-file`.
    static func prepareBookmarksFile(_ options: BookmarkOptions, at url: URL) {
        guard let file = options.file else { return }
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: url)
    }

    /// Nested folders, one empty, and two top-level bookmarks.
    static func seedBookmarkTree(_ store: BrowserBookmarkStore) {
        guard store.tree.isEmpty else { return }
        func bookmark(_ title: String, _ url: String) -> BrowserBookmarkNode {
            .bookmark(BrowserBookmark(url: url, title: title))
        }
        store.insert(.folder(BrowserBookmarkFolder(name: "Work", children: [
            bookmark("Soprano Web", "https://github.com/frknue/soprano_web"),
            .folder(BrowserBookmarkFolder(name: "Docs", children: [
                bookmark("WebKit Documentation", "https://developer.apple.com/documentation/webkit"),
                bookmark("The Swift Programming Language", "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/"),
            ])),
            bookmark("Pull requests", "https://github.com/frknue/soprano_web/pulls"),
        ])))
        store.insert(.folder(BrowserBookmarkFolder(name: "Reading", children: [
            bookmark("WebKit Blog", "https://webkit.org/blog/"),
            bookmark("Hacker News", "https://news.ycombinator.com/"),
        ])))
        store.insert(bookmark("WebKit", "https://webkit.org/"))
        store.insert(bookmark("Swift", "https://www.swift.org/"))
        store.insert(.folder(BrowserBookmarkFolder(name: "Later")))
    }

    /// After the sidebar opens: expand, search and drop, then print.
    static func runBookmarkScenario(_ options: BookmarkOptions, controller: BrowserWindowController) {
        let store = controller.bookmarks
        let sidebar = controller.sidebar
        for name in options.expand {
            let folders = store.tree.folderEntries().filter {
                $0.id != BrowserBookmarkTree.rootID && (name == "all" || $0.name == name)
            }
            for folder in folders {
                sidebar.setFolderExpanded(folder.id, true)
            }
        }
        if let name = options.lastFolder {
            let folder = store.tree.folderEntries().first { $0.name == name }
            controller.manager.bookmarkUIState.lastFolderID = folder?.id
        }
        for (title, drop) in options.drops {
            guard let node = sidebar.outlineRows.first(where: { $0.node.title == title })?.node else {
                print("bookmark-drop: no visible row titled \(title)")
                continue
            }
            let destination = sidebar.bookmarkDestination(for: node.id, drop: drop)
            let moved = sidebar.performBookmarkDrop(node.id, drop: drop)
            let target = destination.flatMap { store.tree.folder(id: $0.folderID)?.displayName } ?? "-"
            print("bookmark-drop: \(title) \(drop) -> \(moved ? "moved into \(target) at \(destination?.index ?? -1)" : "refused")")
        }
        if let search = options.search {
            sidebar.setSearchText(search)
            for entry in store.matching(search) {
                print("bookmark-search: \(entry.bookmark.displayTitle) — \(entry.pathText)")
            }
        }
        if options.print {
            printBookmarks(controller)
        }
    }

    static func printBookmarks(_ controller: BrowserWindowController) {
        let store = controller.bookmarks
        func walk(_ folder: BrowserBookmarkFolder, depth: Int) {
            for node in folder.children {
                let indent = String(repeating: "  ", count: depth)
                switch node {
                case let .bookmark(bookmark):
                    print("bookmark-tree: \(indent)\(bookmark.displayTitle) <\(bookmark.url)>")
                case let .folder(child):
                    print("bookmark-tree: \(indent)\(child.displayName)/")
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(store.tree.root, depth: 0)
        for (index, row) in controller.sidebar.outlineRows.enumerated() {
            let mark = row.node.isFolder ? (row.isExpanded ? "▾ " : "▸ ") : "  "
            print("bookmark-outline: \(index) \(String(repeating: "  ", count: row.depth))\(mark)\(row.node.title)")
        }
        for entry in store.entries {
            print("bookmark-vimium: \(entry.bookmark.displayTitle) | \(entry.detail)")
        }
        let file = (try? Data(contentsOf: store.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        print("bookmark-file: version \(file?["version"] as? Int ?? 0), migrated copy \(FileManager.default.fileExists(atPath: store.migratedURL.path) ? "kept" : "none")")
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
    static func makeBookmarkPopover(_ options: BookmarkOptions, controller: BrowserWindowController) -> NSView? {
        guard options.popover else { return nil }
        guard let result = controller.bookmarkSelectedPage(),
              let editor = controller.makeBookmarkEditor(
                  for: result.bookmark.id,
                  heading: result.added ? "Bookmark Added" : "Edit Bookmark",
                  showsURL: false
              )
        else {
            print("bookmark-popover: nothing to bookmark on this tab")
            return nil
        }
        let root = controller.rootView
        editor.translatesAutoresizingMaskIntoConstraints = true
        editor.layoutSubtreeIfNeeded()
        let anchor = controller.toolbar.bookmarkAnchor
        let anchorRect = anchor.convert(anchor.bounds, to: root)
        editor.frame = BrowserBookmarkEditorView.frame(size: editor.fittingSize, below: anchorRect, within: root.bounds)
        root.addSubview(editor, positioned: .above, relativeTo: nil)
        editor.layoutSubtreeIfNeeded()
        let folder = controller.bookmarks.tree.folder(id: editor.content.folderID)?.displayName ?? "?"
        print("bookmark-popover: \(editor.content.heading) | name \(editor.nameField.stringValue) | folder \(folder) | star \(controller.bookmarks.isBookmarked(result.bookmark.url) ? "filled" : "empty")")
        for line in BrowserBookmarksMenu.dump(editor.folderMenu()) {
            print("bookmark-popover-folders: \(line)")
        }
        return editor
    }
}
