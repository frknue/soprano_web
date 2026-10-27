import AppKit

/// Rail flags for `SopranoWeb snapshot`, run in order with the session
/// actions on the active window, through the handlers a real click calls:
///
/// - `--click-pin <title>[:icon|:cmd-icon]`: a click on the rail's pinned
///   row titled so (the pin's title), on its icon (reset) or ⌘ on its icon
///   (reset, keeping the page in a new Today tab).
/// - `--click-favorite <n|title>[:cmd]`: a click (⌘-click) on favorite n
///   (1-based) or the one titled so.
/// - `--pin-tab`, `--unpin-tab`, `--add-favorite`, `--remove-favorite`,
///   `--replace-pin`: the selected tab's menu items (Pin Tab, Unpin Tab,
///   Add to Favorites, Remove from Favorites, Replace Pin/Favorite with
///   Current Page).
/// - `--new-space "<name>|<icon>|<color>|<profile>"`: the switcher's "+"
///   sheet, filled (empty parts keep the sheet's defaults) and Create
///   Space pressed.
/// - `--edit-space "<space>=<name>|<icon>|<color>|<profile>"`: Edit Space…
///   on that Space's switcher icon, filled and saved.
/// - `--delete-space <name>`: Delete Space on its switcher icon,
///   confirmed.
/// - `--print-rail`: the active window's rail as one JSON line: header,
///   favorites, pinned rows, Today tabs and the switcher, each with its
///   live, selected and "/" state, and every tab of the Space with its
///   link.
enum SnapshotRailAction {
    case clickPin(title: String, icon: Bool, command: Bool)
    case clickFavorite(String, command: Bool)
    case pinTab
    case unpinTab
    case addFavorite
    case removeFavorite
    case replaceLink
    case newSpace(String)
    case editSpace(String)
    case deleteSpace(String)
    case printRail

    static let flags: Set<String> = [
        "--click-pin", "--click-favorite", "--pin-tab", "--unpin-tab", "--add-favorite", "--remove-favorite",
        "--replace-pin", "--new-space", "--edit-space", "--delete-space", "--print-rail",
    ]

    static let usage = """
                               [--click-pin <title>[:icon|:cmd-icon]]... [--click-favorite <n|title>[:cmd]]...
                               [--pin-tab] [--unpin-tab] [--add-favorite] [--remove-favorite] [--replace-pin]
                               [--new-space "<name>|<icon>|<color>|<profile>"]...
                               [--edit-space "<space>=<name>|<icon>|<color>|<profile>"] [--delete-space <name>]
                               [--print-rail]
    """

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotRailAction? {
        switch option {
        case "--click-pin":
            let raw = try value()
            if raw.hasSuffix(":cmd-icon") {
                return .clickPin(title: String(raw.dropLast(":cmd-icon".count)), icon: true, command: true)
            }
            if raw.hasSuffix(":icon") {
                return .clickPin(title: String(raw.dropLast(":icon".count)), icon: true, command: false)
            }
            return .clickPin(title: raw, icon: false, command: false)
        case "--click-favorite":
            let raw = try value()
            if raw.hasSuffix(":cmd") {
                return .clickFavorite(String(raw.dropLast(":cmd".count)), command: true)
            }
            return .clickFavorite(raw, command: false)
        case "--pin-tab": return .pinTab
        case "--unpin-tab": return .unpinTab
        case "--add-favorite": return .addFavorite
        case "--remove-favorite": return .removeFavorite
        case "--replace-pin": return .replaceLink
        case "--new-space": return .newSpace(try value())
        case "--edit-space": return .editSpace(try value())
        case "--delete-space": return .deleteSpace(try value())
        case "--print-rail": return .printRail
        default: return nil
        }
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        guard let controller = manager.activeController else {
            print("snapshot: no window is open")
            return
        }
        let rail = controller.verticalTabsView
        switch self {
        case let .clickPin(title, icon, command):
            controller.updateRail()
            guard let row = rail.pinsView.rows.firstIndex(where: { $0.row.node.pin?.displayTitle == title }) else {
                print("click-pin: no pinned row titled \(title)")
                return
            }
            let before = controller.tabs.count
            rail.pinsView.click(row: row, onIcon: icon, command: command)
            let selected = controller.selectedTab
            print("click-pin: \(title)\(icon ? (command ? " ⌘icon" : " icon") : "") -> selected \(selected.map(Self.describe) ?? "-") | tabs \(before) -> \(controller.tabs.count)")
        case let .clickFavorite(key, command):
            controller.updateRail()
            let items = rail.favoritesView.items
            let index = Int(key).map { $0 - 1 } ?? items.firstIndex { $0.title == key }
            guard let index, items.indices.contains(index) else {
                print("click-favorite: no favorite \(key)")
                return
            }
            let before = controller.tabs.count
            rail.favoritesView.click(items[index].id, command: command)
            let selected = controller.selectedTab
            print("click-favorite: \(items[index].title)\(command ? " ⌘" : "") -> selected \(selected.map(Self.describe) ?? "-") | tabs \(before) -> \(controller.tabs.count)")
        case .pinTab, .unpinTab, .addFavorite, .removeFavorite, .replaceLink:
            guard let tab = controller.selectedTab else { return }
            let title = switch self {
            case .pinTab: "Pin Tab"
            case .unpinTab: "Unpin Tab"
            case .addFavorite: "Add to Favorites"
            case .removeFavorite: "Remove from Favorites"
            default: tab.origin.favoriteID != nil ? "Replace Favorite with Current Page" : "Replace Pin with Current Page"
            }
            let menu = controller.tabContextMenu(for: tab.id, closeAfterTitle: "Close Tabs Below")
            guard let item = menu?.items.first(where: { $0.title == title }), item.isEnabled, let action = item.action else {
                print("tab-menu: \(title) unavailable on \(tab.displayTitle)")
                return
            }
            NSApp.sendAction(action, to: item.target, from: item)
            print("tab-menu: \(title) -> \(Self.describe(tab))")
        case let .newSpace(raw):
            let sheet = controller.makeSpaceSheet(editing: nil)
            Self.fill(sheet, with: raw, manager: manager)
            sheet.savePressed()
            let space = controller.currentSpaceID.flatMap(manager.spaces.space(id:))
            print("new-space: \(sheet.message.isEmpty ? "created \(space.map(Self.describe) ?? "-"), window shows it" : "refused: \(sheet.message)")")
        case let .editSpace(raw):
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let space = Self.space(named: parts[0], in: manager) else {
                print("edit-space: no Space \(raw)")
                return
            }
            let sheet = controller.makeSpaceSheet(editing: space.id)
            Self.fill(sheet, with: parts[1], manager: manager)
            sheet.savePressed()
            let saved = manager.spaces.space(id: space.id)
            print("edit-space: \(sheet.message.isEmpty ? "saved \(saved.map(Self.describe) ?? "-")" : "refused: \(sheet.message)")")
        case let .deleteSpace(name):
            guard let space = Self.space(named: name, in: manager) else {
                print("delete-space: no Space \(name)")
                return
            }
            let deleted = controller.deleteSpace(space.id, confirmed: true)
            print("delete-space: \(space.displayName) \(deleted ? "deleted" : "refused (its profile's only Space)")")
        case .printRail:
            print(Self.railJSON(controller))
        }
    }

    @MainActor
    private static func space(named name: String, in manager: BrowserWindowManager) -> BrowserSpace? {
        manager.spaces.spaces.first { $0.displayName == name }
    }

    /// Fills the sheet from "<name>|<icon>|<color>|<profile>" as typing and
    /// clicking would; empty parts stay as they are.
    @MainActor
    static func fill(_ sheet: BrowserSpaceSheet, with raw: String, manager: BrowserWindowManager) {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func part(_ index: Int) -> String? {
            parts.indices.contains(index) && !parts[index].isEmpty ? parts[index] : nil
        }
        sheet.fill(
            name: part(0),
            icon: part(1),
            color: part(2).flatMap(BrowserProfileColor.init(rawValue:)),
            profileID: part(3).flatMap { manager.profiles.profile(named: $0)?.id }
        )
    }

    @MainActor
    static func describe(_ tab: BrowserTab) -> String {
        let link = switch tab.origin {
        case .today: "today"
        case .pinned: "pinned"
        case .favorite: "favorite"
        }
        return "\(tab.displayTitle) <\(tab.item.url?.absoluteString ?? "start")> [\(link)] tab \(tab.id.uuidString.prefix(8))"
    }

    @MainActor
    static func describe(_ space: BrowserSpace) -> String {
        let icon = switch space.icon {
        case .none: "none"
        case let .emoji(value): "emoji \(value)"
        case let .symbol(value): "symbol \(value)"
        }
        return "\(space.displayName) (icon \(icon), color \(space.color.rawValue), profile \(space.profileID == BrowserProfile.defaultID ? "Default" : space.profileID.uuidString))"
    }

    /// What the rail shows, as one JSON line.
    @MainActor
    static func railJSON(_ controller: BrowserWindowController) -> String {
        controller.updateRail()
        let rail = controller.verticalTabsView
        let content = rail.content
        let manager = controller.manager
        let favorites: [[String: Any]] = content.favorites.map {
            ["title": $0.title, "url": $0.url, "live": $0.isLive, "selected": $0.isSelected, "mark": $0.isAway ? "/" : ""]
        }
        let pinned: [[String: Any]] = content.pins.enumerated().map { index, row in
            var entry: [String: Any] = [
                "row": index,
                "depth": row.row.depth,
                "title": row.row.node.title,
                "kind": row.row.node.isFolder ? "folder" : "pin",
            ]
            if row.row.node.isFolder {
                entry["expanded"] = row.row.isExpanded
            } else {
                entry["url"] = row.row.node.pin?.url ?? ""
                entry["live"] = row.isLive
                entry["selected"] = row.isSelected
                entry["mark"] = row.isAway ? "/" : ""
                entry["shownTitle"] = row.isLive ? (row.liveTitle ?? row.row.node.title) : row.row.node.title
            }
            return entry
        }
        let today: [[String: Any]] = rail.todayItems.map {
            ["title": $0.title, "url": $0.url?.absoluteString ?? "start", "selected": $0.id == rail.selectedID]
        }
        let switcher: [[String: Any]] = content.spaces.map { space in
            let icon = switch space.icon {
            case .none: "none"
            case let .emoji(value): "emoji \(value)"
            case let .symbol(value): "symbol \(value)"
            }
            return ["name": space.name, "icon": icon, "color": space.color.rawValue, "current": space.isCurrent]
        }
        let tabs: [[String: Any]] = controller.visibleTabs.map { tab in
            let link: String = switch tab.origin {
            case .today: "today"
            case .pinned: "pinned"
            case .favorite: "favorite"
            }
            return [
                "title": tab.displayTitle,
                "url": tab.item.url?.absoluteString ?? "start",
                "origin": link,
                "pinnedURL": controller.linkedURL(of: tab) ?? NSNull(),
                "mark": controller.isAway(tab) ? "/" : "",
                "selected": tab === controller.selectedTab,
            ]
        }
        let object: [String: Any] = [
            "header": rail.headerText,
            "showsSpaces": content.showsSpaces,
            "space": controller.currentSpaceID.flatMap(manager.spaces.space(id:))?.displayName ?? NSNull(),
            "favorites": favorites,
            "pinned": pinned,
            "today": today,
            "switcher": switcher,
            "tabs": tabs,
            "recentlyClosed": manager.recentlyClosed.entries.count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return "rail: " + String(decoding: data, as: UTF8.self)
    }
}

extension SnapshotCommand {
    /// `--pin-preview <folder>` / `--pin-search <text>`: the rail's folder
    /// preview as resting on the folder shows it, the search typed in; the
    /// capture draws it over the page.
    static func makePinPreview(_ options: PinOptions, controller: BrowserWindowController) -> NSView? {
        guard options.preview != nil || options.search != nil else { return nil }
        controller.updateRail()
        let rows = controller.verticalTabsView.pinsView.rows
        let folderRow = options.preview.flatMap { name in rows.first { $0.row.node.folder?.displayName == name } }
            ?? rows.first { $0.row.node.isFolder }
        guard let folderRow else {
            print("pin-preview: no folder row in the rail")
            return nil
        }
        controller.verticalTabsView.pinsView.previewFolder(folderRow.id)
        guard let preview = controller.folderPreview else {
            print("pin-preview: not shown")
            return nil
        }
        if let search = options.search {
            preview.setSearchText(search)
        }
        for entry in preview.shown {
            print("pin-search: \(entry.pin.displayTitle) — \(entry.pathText)")
        }
        print("pin-preview: \(folderRow.row.node.title), \(preview.shown.count) shown")
        return preview
    }

    /// `--space-sheet new|<space>[=<fill>]`: the New Space / Edit Space
    /// sheet, built for the capture and never shown.
    static func makeSpaceSheet(_ options: PinOptions, controller: BrowserWindowController) -> BrowserSpaceSheet? {
        guard let raw = options.spaceSheet else { return nil }
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        let target = parts.first ?? "new"
        let spaceID = target == "new" ? nil : controller.spaces.spaces.first { $0.displayName == target }?.id
        if target != "new", spaceID == nil {
            print("space-sheet: no Space \(target)")
        }
        let sheet = controller.makeSpaceSheet(editing: spaceID)
        if parts.count == 2 {
            SnapshotRailAction.fill(sheet, with: parts[1], manager: controller.manager)
        }
        sheet.window?.contentView?.layoutSubtreeIfNeeded()
        print("space-sheet: \(sheet.window?.title ?? "-") | name \(sheet.nameField.stringValue) | icon \(sheet.iconField.stringValue) | color \(sheet.values.color.rawValue) | \(sheet.profilePicker.button.isHidden ? "one profile" : sheet.profilePicker.button.title) | \(sheet.saveButton.title)\(sheet.saveButton.isEnabled ? "" : " (disabled)")")
        return sheet
    }
}
