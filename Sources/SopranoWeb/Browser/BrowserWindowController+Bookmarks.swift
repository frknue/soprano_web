import AppKit

/// ⌘D and the star's popover, and what the sidebar's Bookmarks outline asks
/// for: open, Open All in Tabs, New Folder, Edit/Rename and Delete. All of
/// it reads and writes the pins of the window's current Space
/// (`currentSpaceID`). Private windows may pin too (a deliberate save).
extension BrowserWindowController {
    // MARK: - ⌘D and the star

    /// The star. A click that just closed the popover (the click took key
    /// from it) doesn't open it again.
    func starPressed() {
        if let resigned = bookmarkEditorPanel.lastResignedAt, Date().timeIntervalSince(resigned) < 0.3 {
            return
        }
        bookmarkCurrentPage()
    }

    /// ⌘D: a page that isn't pinned goes into the folder ⌘D last used in
    /// this Space (the top level at first); either way the popover opens
    /// under the star to name, file or remove it.
    func bookmarkCurrentPage() {
        guard let window, let result = bookmarkSelectedPage() else {
            NSSound.beep()
            return
        }
        guard let editor = makeBookmarkEditor(
            for: result.pin.id,
            heading: result.added ? "Bookmark Added" : "Edit Bookmark",
            showsURL: false
        ) else { return }
        bookmarkEditorPanel.show(editor, below: toolbar.bookmarkAnchor, in: window)
    }

    /// Pins the selected page in the current Space unless it is pinned
    /// there; returns its pin and whether it is new. Nil on the start page,
    /// an empty tab or without a Space.
    func bookmarkSelectedPage() -> (pin: BrowserPin, added: Bool)? {
        guard let spaceID = currentSpaceID, let tab = selectedTab, !tab.isStartPage,
              let address = tab.webView.url?.absoluteString
        else {
            return nil
        }
        if let existing = spaces.pin(url: address, inSpace: spaceID) {
            return (existing, false)
        }
        let folder = spaces.pinTree(inSpace: spaceID)
            .folderForNewPin(lastUsed: manager.pinUIState.lastFolderID(inSpace: spaceID))
        guard let pin = spaces.addPin(url: address, title: tab.displayTitle, to: folder, inSpace: spaceID) else {
            return nil
        }
        updateChrome()
        return (pin, true)
    }

    /// The editor for pin or folder `id` of the current Space, wired to the
    /// store. The panel shows it; the harness captures it offscreen instead.
    func makeBookmarkEditor(for id: UUID, heading: String, showsURL: Bool) -> BrowserPinEditorView? {
        guard let spaceID = currentSpaceID else { return nil }
        let tree = spaces.pinTree(inSpace: spaceID)
        guard let node = tree.node(id: id), let location = tree.location(of: id) else { return nil }
        let isFolder = node.isFolder
        let content = BrowserPinEditorContent(
            heading: heading,
            name: node.folder?.name ?? node.pin?.title ?? "",
            namePlaceholder: isFolder ? "Folder name" : "Name",
            url: showsURL ? node.pin?.url : nil,
            folderID: location.folderID,
            folders: tree.folderEntries(excluding: isFolder ? id : nil),
            removeTitle: isFolder ? "Delete" : "Remove"
        )
        let editor = BrowserPinEditorView(theme: theme, content: content)
        editor.onFolderChange = { [weak self] folderID in
            guard let self else { return }
            self.spaces.movePin(id, to: folderID, at: 0, inSpace: spaceID)
            if !isFolder {
                self.manager.pinUIState.setLastFolderID(folderID, inSpace: spaceID)
            }
        }
        editor.onDone = { [weak self] name, address in
            guard let self else { return }
            self.bookmarkEditorPanel.close(saving: false)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch self.spaces.pinTree(inSpace: spaceID).node(id: id) {
            case .folder:
                self.spaces.renamePinFolder(id, to: name, inSpace: spaceID)
            case let .pin(pin):
                let url = address.flatMap(BrowserPinEditorContent.address(from:)) ?? pin.url
                self.spaces.editPin(id, title: name, url: url, inSpace: spaceID)
            case nil:
                break
            }
        }
        editor.onRemove = { [weak self] in
            self?.bookmarkEditorPanel.close(saving: false)
            self?.deleteBookmarkNode(id)
        }
        editor.onCancel = { [weak self] in
            self?.bookmarkEditorPanel.close(saving: false)
        }
        return editor
    }

    // MARK: - Sidebar and menu actions

    /// Opens every pin in the folder (subfolders included) in new tabs and
    /// selects the first.
    func openBookmarkFolderInTabs(_ id: UUID) {
        guard let folder = currentPinTree.folder(id: id), let first = folder.allPins.first else { return }
        let firstTab = newTab(url: first.url, select: false)
        for pin in folder.allPins.dropFirst() {
            newTab(url: pin.url, select: false)
        }
        if tabs.contains(where: { $0 === firstTab }) {
            selectTab(id: firstTab.id, focus: true)
        }
    }

    /// Adds "New Folder" in `parentID` at `index`, shows it in the outline
    /// and opens the editor on it to name it.
    func newBookmarkFolder(in parentID: UUID, at index: Int?) {
        guard let spaceID = currentSpaceID,
              let folder = spaces.addPinFolder(name: "New Folder", in: parentID, at: index, inSpace: spaceID)
        else { return }
        sidebar.revealBookmarkNode(folder.id)
        guard let window, let anchor = sidebar.anchorView(forBookmarkNode: folder.id),
              let editor = makeBookmarkEditor(for: folder.id, heading: "New Folder", showsURL: false)
        else { return }
        bookmarkEditorPanel.show(editor, below: anchor, in: window)
    }

    /// Edit Bookmark (name, address, folder) or Rename (a folder), under
    /// the row.
    func editBookmarkNodeFromSidebar(_ id: UUID) {
        guard let window, let node = currentPinTree.node(id: id) else { return }
        guard let anchor = sidebar.anchorView(forBookmarkNode: id),
              let editor = makeBookmarkEditor(
                  for: id,
                  heading: node.isFolder ? "Rename Folder" : "Edit Bookmark",
                  showsURL: !node.isFolder
              )
        else { return }
        bookmarkEditorPanel.show(editor, below: anchor, in: window)
    }

    /// Deletes a pin or an empty folder at once; a folder with contents
    /// asks first.
    func deleteBookmarkNode(_ id: UUID) {
        guard let spaceID = currentSpaceID, let node = spaces.pinTree(inSpace: spaceID).node(id: id) else { return }
        guard let folder = node.folder, !folder.children.isEmpty else {
            spaces.removePin(id, inSpace: spaceID)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(folder.displayName)”?"
        alert.informativeText = "\(folder.contentsSummary) This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.spaces.removePin(id, inSpace: spaceID)
        }
    }
}
