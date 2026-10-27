import AppKit

/// The rail (vertical tabs): what it shows — the Space header, Favorites,
/// the pinned outline, the Today tabs, the Space switcher — and what its
/// clicks, menus, drops and the folder preview do. A window without Spaces
/// (private, pop-up) shows its tabs only.
extension BrowserWindowController {
    // MARK: - Wiring

    func wireRail() {
        let rail = verticalTabsView
        rail.favoritesView.onClick = { [weak self] id, command in self?.favoritePressed(id, command: command) }
        rail.favoritesView.menuProvider = { [weak self] id in self?.favoriteMenu(for: id) }
        rail.pinsView.onOpenPin = { [weak self] id in self?.openPin(id) }
        rail.pinsView.onPinIcon = { [weak self] id, command in
            self?.pinIconPressed(.pinned(id), keepingPage: command)
        }
        rail.pinsView.onToggleFolder = { [weak self] id in self?.togglePinFolder(id) }
        rail.pinsView.menuProvider = { [weak self] id in self?.pinMenu(for: id) }
        rail.pinsView.canDrop = { [weak self] id, drop in self?.bookmarkDestination(for: id, drop: drop) != nil }
        rail.pinsView.onDrop = { [weak self] id, drop in self?.performBookmarkDrop(id, drop: drop) ?? false }
        rail.pinsView.onHoverFolder = { [weak self] id, frame in self?.folderHovered(id, rowFrame: frame) }
        rail.switcher.onSelect = { [weak self] id in self?.switchToSpace(id) }
        rail.switcher.onNewSpace = { [weak self] in self?.presentSpaceSheet(editing: nil) }
        rail.switcher.menuProvider = { [weak self] id in self?.spaceMenu(for: id) }
    }

    // MARK: - Content

    /// The rail header: the current Space (icon, name, color mark) in a
    /// window with Spaces, else the window's mark.
    var railMark: BrowserWindowMark {
        if let space = currentSpaceID.flatMap(spaces.space(id:)) {
            let profile = manager.profiles.hasSeveral ? manager.profile(of: self) : nil
            return BrowserWindowMark(space: space, profile: profile)
        }
        return manager.windowMark(for: self)
    }

    /// The current Space's Today tabs (every tab in a window without
    /// Spaces), in rail order.
    var todayTabs: [BrowserTab] {
        hasSpaces ? visibleTabs.filter { $0.origin == .today } : visibleTabs
    }

    /// The rail's pinned outline: the folders the user expanded (opening a
    /// pin reveals it once, `revealPinNode`, so it can be closed again).
    var railOutlineRows: [BrowserPinOutline.Row] {
        guard hasSpaces else { return [] }
        return BrowserPinOutline.rows(currentPinTree, expanded: manager.pinUIState.expandedFolders)
    }

    /// Refreshes the rail: its sections and the Today tabs.
    func updateRail() {
        guard let selected = selectedTab else { return }
        verticalTabsView.update(content: railContent(selected: selected))
        verticalTabsView.update(tabs: todayTabs.map(tabItem), selectedID: selected.id)
    }

    private func railContent(selected: BrowserTab) -> BrowserRailContent {
        guard hasSpaces, let spaceID = currentSpaceID else { return BrowserRailContent() }
        let favicons = dataContext.faviconStore
        let favorites = spaces.favorites(ofProfile: profileID).map { favorite in
            let tab = liveTab(for: .favorite(favorite.id))
            return BrowserRailFavorite(
                id: favorite.id,
                title: favorite.displayTitle,
                url: favorite.url,
                favicon: tab?.favicon ?? favicons.image(forAddress: favorite.url),
                isLive: tab != nil,
                isSelected: tab === selected,
                isAway: tab.map(isAway) ?? false
            )
        }
        let pins = railOutlineRows.map { row -> BrowserRailPinRow in
            guard let pin = row.node.pin else { return BrowserRailPinRow(row: row) }
            let tab = liveTab(for: .pinned(pin.id))
            return BrowserRailPinRow(
                row: row,
                favicon: tab?.favicon ?? favicons.image(forAddress: pin.url),
                isLive: tab != nil,
                isSelected: tab === selected,
                isAway: tab.map(isAway) ?? false,
                liveTitle: tab?.displayTitle
            )
        }
        let spaceItems = spaces.spaces.map { space in
            BrowserRailSpace(
                id: space.id,
                name: space.displayName,
                icon: space.icon,
                color: space.color,
                isCurrent: space.id == spaceID
            )
        }
        return BrowserRailContent(showsSpaces: true, favorites: favorites, pins: pins, spaces: spaceItems)
    }

    // MARK: - Today tabs

    /// A Today row dragged to index `index` of the Today tabs.
    func moveTodayTab(id: UUID, toTodayIndex index: Int) {
        let linked = visibleTabs.count - todayTabs.count
        moveTab(id: id, toIndex: linked + index)
    }

    /// Gap `gap` of the Today tabs as a gap of `visibleTabs`.
    func visibleGap(forTodayGap gap: Int) -> Int {
        visibleTabs.count - todayTabs.count + gap
    }

    /// Gap `gap` of `visibleTabs` as `attachTab`'s index (counted among the
    /// Space's tabs in window order); nil is the end.
    func spaceIndex(forVisibleGap gap: Int) -> Int? {
        guard visibleTabs.indices.contains(gap) else { return nil }
        let target = visibleTabs[gap]
        return tabs.filter { $0.spaceID == currentSpaceID }.firstIndex { $0 === target }
    }

    // MARK: - Favorites

    /// A favorite's tile: opens or selects its live tab; on the selected
    /// tile whose page moved on it sends the tab back (⌘: keeping the
    /// page in a new Today tab).
    func favoritePressed(_ id: UUID, command: Bool) {
        if let tab = liveTab(for: .favorite(id)), tab === selectedTab, isAway(tab) {
            resetLinkedTab(tab, keepingPage: command)
        } else {
            openFavorite(id)
        }
    }

    private func favoriteMenu(for id: UUID) -> NSMenu? {
        guard let favorite = spaces.favorites(ofProfile: profileID).first(where: { $0.id == id }) else { return nil }
        let tab = liveTab(for: .favorite(id))
        let menu = NSMenu(title: favorite.displayTitle)
        menu.autoenablesItems = false
        menu.addItem(menuItem("Open", #selector(openFavoriteFromMenu(_:)), id))
        menu.addItem(menuItem("Copy Link", #selector(copyFavoriteLinkFromMenu(_:)), id))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Replace Favorite with Current Page",
            #selector(replaceLinkFromMenu(_:)),
            tab?.id,
            enabled: tab.map(isAway) ?? false
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem("Remove from Favorites", #selector(removeFavoriteFromMenu(_:)), id))
        return menu
    }

    @objc private func openFavoriteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openFavorite(id)
    }

    @objc private func copyFavoriteLinkFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let favorite = spaces.favorites(ofProfile: profileID).first(where: { $0.id == id })
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(favorite.url, forType: .string)
    }

    @objc private func removeFavoriteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        removeFavorite(id)
    }

    // MARK: - Pinned outline

    func setPinFolderExpanded(_ id: UUID, _ expanded: Bool) {
        manager.pinUIState.setExpanded(expanded, folder: id)
        updateRail()
    }

    func togglePinFolder(_ id: UUID) {
        setPinFolderExpanded(id, !manager.pinUIState.expandedFolders.contains(id))
    }

    /// Expands every folder above `id` so its row shows.
    func revealPinNode(_ id: UUID) {
        var current = id
        let tree = currentPinTree
        while let location = tree.location(of: current), location.folderID != BrowserPinTree.rootID {
            manager.pinUIState.setExpanded(true, folder: location.folderID)
            current = location.folderID
        }
        updateRail()
    }

    /// The rail row showing `id` for the editor to hang from; the star
    /// when the rail is hidden.
    func pinAnchorView(_ id: UUID) -> NSView {
        if !verticalTabsView.isHidden, let row = verticalTabsView.pinsView.rowView(for: id) {
            verticalTabsView.layoutSubtreeIfNeeded()
            return row
        }
        return toolbar.bookmarkAnchor
    }

    /// Where a drop of `id` on the rail's outline would land, or nil when
    /// it can't (a folder into itself, on a pin). The drop's row numbers
    /// are the rows the rail shows.
    func bookmarkDestination(for id: UUID, drop: BrowserPinOutline.Drop) -> BrowserPinOutline.Destination? {
        let tree = currentPinTree
        let rows = verticalTabsView.pinsView.rows.map(\.row)
        guard hasSpaces,
              let destination = BrowserPinOutline.destination(for: drop, rows: rows, tree: tree),
              tree.canMove(id, into: destination.folderID)
        else { return nil }
        return destination
    }

    /// The outline's drop handler: moves `id` where `drop` lands. A real
    /// drop on the rail and the harness's `--pin-drop` both come here.
    @discardableResult
    func performBookmarkDrop(_ id: UUID, drop: BrowserPinOutline.Drop) -> Bool {
        guard let spaceID = pinSpaceID, let destination = bookmarkDestination(for: id, drop: drop) else { return false }
        return spaces.movePin(id, to: destination.folderID, at: destination.index, inSpace: spaceID)
    }

    private func pinMenu(for id: UUID?) -> NSMenu? {
        let menu = NSMenu(title: "Pinned")
        menu.autoenablesItems = false
        guard let id, let node = currentPinTree.node(id: id) else {
            menu.addItem(menuItem("New Folder", #selector(newPinFolderFromMenu(_:)), nil))
            return menu
        }
        switch node {
        case let .folder(folder):
            menu.addItem(menuItem("Open All in Tabs", #selector(openPinFolderFromMenu(_:)), id, enabled: !folder.allPins.isEmpty))
            menu.addItem(.separator())
            menu.addItem(menuItem("Rename…", #selector(editPinFromMenu(_:)), id))
            menu.addItem(menuItem("New Folder", #selector(newPinFolderFromMenu(_:)), id))
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete", #selector(deletePinFromMenu(_:)), id))
        case .pin:
            let tab = liveTab(for: .pinned(id))
            menu.addItem(menuItem("Open", #selector(openPinFromMenu(_:)), id))
            menu.addItem(menuItem("Copy Link", #selector(copyPinLinkFromMenu(_:)), id))
            menu.addItem(.separator())
            menu.addItem(menuItem(
                "Replace Pin with Current Page",
                #selector(replaceLinkFromMenu(_:)),
                tab?.id,
                enabled: tab.map(isAway) ?? false
            ))
            menu.addItem(menuItem("Edit Pin…", #selector(editPinFromMenu(_:)), id))
            menu.addItem(menuItem("New Folder", #selector(newPinFolderFromMenu(_:)), id))
            menu.addItem(.separator())
            menu.addItem(menuItem("Delete", #selector(deletePinFromMenu(_:)), id))
        }
        return menu
    }

    @objc private func openPinFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openPin(id)
    }

    @objc private func copyPinLinkFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let pin = currentPinTree.node(id: id)?.pin else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin.url, forType: .string)
    }

    @objc private func openPinFolderFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openBookmarkFolderInTabs(id)
    }

    @objc private func editPinFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        editBookmarkNodeFromSidebar(id)
    }

    @objc private func deletePinFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteBookmarkNode(id)
    }

    /// In a folder: first inside it. On a pin: right after it. Elsewhere:
    /// at the end of the top level.
    @objc private func newPinFolderFromMenu(_ sender: NSMenuItem) {
        let tree = currentPinTree
        guard let id = sender.representedObject as? UUID, let node = tree.node(id: id),
              let location = tree.location(of: id)
        else {
            newBookmarkFolder(in: BrowserPinTree.rootID, at: nil)
            return
        }
        if node.isFolder {
            newBookmarkFolder(in: id, at: 0)
        } else {
            newBookmarkFolder(in: location.folderID, at: location.index + 1)
        }
    }

    /// Replace Pin (or Favorite) with Current Page, from the rail's menus
    /// and the tab menu; the item carries the live tab's id.
    @objc func replaceLinkFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        replaceLink(with: tab)
    }

    private func menuItem(_ title: String, _ action: Selector, _ id: UUID?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = enabled
        return item
    }

    // MARK: - Folder preview

    /// The rail reports the pointer resting on folder `id` (its row's
    /// frame in the outline) or leaving it (nil): the preview opens beside
    /// the rail, and closes once the pointer is in neither.
    func folderHovered(_ id: UUID?, rowFrame: NSRect) {
        folderPreviewHideTimer?.invalidate()
        folderPreviewHideTimer = nil
        guard let id else {
            guard folderPreview != nil else { return }
            folderPreviewHideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.folderPreview?.isPointerInside != true else { return }
                    self.closeFolderPreview()
                }
            }
            return
        }
        showFolderPreview(id, rowFrame: rowFrame)
    }

    /// Shows folder `id`'s preview next to its row (the hover, and the
    /// harness's `--pin-preview`).
    @discardableResult
    func showFolderPreview(_ id: UUID, rowFrame: NSRect) -> BrowserPinFolderPreview? {
        guard let folder = currentPinTree.folder(id: id) else { return nil }
        if let folderPreview, folderPreview.folderID == id {
            return folderPreview
        }
        closeFolderPreview()
        let preview = BrowserPinFolderPreview(
            folder: folder,
            entries: Self.entries(in: folder),
            theme: theme,
            favicons: { [weak self] address in self?.dataContext.faviconStore.image(forAddress: address) }
        )
        preview.onOpenPin = { [weak self] pinID in
            self?.closeFolderPreview()
            self?.openPin(pinID)
        }
        preview.onExit = { [weak self] in self?.closeFolderPreview() }
        preview.translatesAutoresizingMaskIntoConstraints = true
        preview.layoutSubtreeIfNeeded()
        let size = preview.fittingSize
        let row = verticalTabsView.pinsView.convert(rowFrame, to: rootView)
        let y = max(8, min(row.maxY + 10, rootView.bounds.maxY - 8) - size.height)
        preview.frame = NSRect(x: verticalTabsView.frame.maxX + 6, y: y, width: size.width, height: size.height)
        rootView.addSubview(preview, positioned: .above, relativeTo: nil)
        preview.layoutSubtreeIfNeeded()
        folderPreview = preview
        return preview
    }

    func closeFolderPreview() {
        folderPreviewHideTimer?.invalidate()
        folderPreviewHideTimer = nil
        folderPreview?.removeFromSuperview()
        folderPreview = nil
    }

    /// Closes the preview when what it shows is gone: the rail is hidden,
    /// the window shows another Space, or the folder or its pins changed.
    func syncFolderPreview() {
        guard let folderPreview else { return }
        guard !verticalTabsView.isHidden,
              let folder = currentPinTree.folder(id: folderPreview.folderID),
              Self.entries(in: folder) == folderPreview.entries
        else {
            closeFolderPreview()
            return
        }
    }

    /// Every pin in `folder` and its subfolders, with the path from it.
    static func entries(in folder: BrowserPinFolder) -> [BrowserPinEntry] {
        var result: [BrowserPinEntry] = []
        func walk(_ folder: BrowserPinFolder, path: [String]) {
            for node in folder.children {
                switch node {
                case let .pin(pin):
                    result.append(BrowserPinEntry(pin: pin, folderID: folder.id, path: path))
                case let .folder(child):
                    walk(child, path: path + [child.displayName])
                }
            }
        }
        walk(folder, path: [folder.displayName])
        return result
    }

    // MARK: - Space switcher

    private func spaceMenu(for id: UUID) -> NSMenu? {
        guard let space = spaces.space(id: id) else { return nil }
        let menu = NSMenu(title: space.displayName)
        menu.autoenablesItems = false
        menu.addItem(menuItem("Edit Space…", #selector(editSpaceFromMenu(_:)), id))
        menu.addItem(.separator())
        let delete = menuItem("Delete Space", #selector(deleteSpaceFromMenu(_:)), id, enabled: canDeleteSpace(id))
        if !delete.isEnabled {
            delete.toolTip = "A profile keeps at least one Space."
        }
        menu.addItem(delete)
        return menu
    }

    /// A profile's last Space can't be deleted.
    func canDeleteSpace(_ id: UUID) -> Bool {
        guard let space = spaces.space(id: id) else { return false }
        return spaces.spaces(ofProfile: space.profileID).count > 1
    }

    @objc private func editSpaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        presentSpaceSheet(editing: id)
    }

    @objc private func deleteSpaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteSpace(id, confirmed: false)
    }

    /// Delete Space: asks first (its pins go, its open tabs close onto
    /// Recently Closed); refused for a profile's last Space. Returns
    /// whether it was deleted (always false while asking).
    @discardableResult
    func deleteSpace(_ id: UUID, confirmed: Bool) -> Bool {
        guard let space = spaces.space(id: id), canDeleteSpace(id) else {
            NSSound.beep()
            return false
        }
        if confirmed {
            return spaces.deleteSpace(id)
        }
        guard let window else { return false }
        let pins = spaces.pinTree(inSpace: id).root.allPins.count
        let open = manager.controllers.reduce(0) { count, controller in
            count + controller.tabs.filter { $0.spaceID == id }.count
        }
        let alert = NSAlert()
        alert.messageText = "Delete the Space “\(space.displayName)”?"
        let pinsText = pins == 0 ? "It has no pinned tabs." : "Its \(pins == 1 ? "pinned tab goes" : "\(pins) pinned tabs go")."
        let openText = open == 0 ? "" : " \(open == 1 ? "Its open tab closes" : "Its \(open) open tabs close") in every window."
        alert.informativeText = pinsText + openText + " This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.spaces.deleteSpace(id)
        }
        return false
    }

    /// New Space (`editing` nil, the switcher's "+") or Edit Space…, as a
    /// sheet on the window.
    func presentSpaceSheet(editing id: UUID?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = makeSpaceSheet(editing: id)
        spaceSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.spaceSheet = nil
        }
        sheetWindow.makeFirstResponder(sheet.nameField)
    }

    /// The New Space / Edit Space sheet, wired to the Space store; the
    /// harness fills and captures it without presenting it.
    func makeSpaceSheet(editing id: UUID?) -> BrowserSpaceSheet {
        let space = id.flatMap(spaces.space(id:))
        let used = Set(spaces.spaces.map(\.color))
        let color = BrowserProfileColor.allCases.first { !used.contains($0) }
            ?? BrowserProfileColor.allCases[spaces.spaces.count % BrowserProfileColor.allCases.count]
        let sheet = BrowserSpaceSheet(
            space: space,
            profileID: profileID,
            color: color,
            profileLocked: space.map { spaces.spaces(ofProfile: $0.profileID).count <= 1 } ?? false,
            profiles: manager.profiles,
            theme: theme
        )
        sheet.onSave = { [weak self] values in
            guard let self else { return "The window closed." }
            return self.saveSpace(values, editing: id)
        }
        return sheet
    }

    /// Creates the Space (and shows it in this window) or saves the edit;
    /// returns why not when refused.
    private func saveSpace(_ values: BrowserSpaceSheetValues, editing id: UUID?) -> String? {
        guard let id else {
            guard let space = spaces.createSpace(
                name: values.name,
                icon: values.icon,
                color: values.color,
                profileID: values.profileID
            ) else { return "The Space could not be created." }
            switchToSpace(space.id)
            return nil
        }
        guard let space = spaces.space(id: id) else { return "The Space is gone." }
        if values.profileID != space.profileID, !spaces.setSpaceProfile(id, values.profileID) {
            return "“\(space.displayName)” is its profile's only Space, so it stays in that profile."
        }
        spaces.renameSpace(id, to: values.name)
        spaces.setSpaceIcon(id, values.icon)
        spaces.setSpaceColor(id, values.color)
        return nil
    }
}
