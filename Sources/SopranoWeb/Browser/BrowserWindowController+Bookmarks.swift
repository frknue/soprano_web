import AppKit

/// ⌘D and the star's popover, and what the sidebar's Bookmarks outline asks
/// for: open, Open All in Tabs, New Folder, Edit/Rename and Delete.
/// Private windows may add bookmarks too (a deliberate save).
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

    /// ⌘D: a page that isn't bookmarked goes into the folder ⌘D last used
    /// (the top level at first); either way the popover opens under the
    /// star to name, file or remove it.
    func bookmarkCurrentPage() {
        guard let window, let result = bookmarkSelectedPage() else {
            NSSound.beep()
            return
        }
        guard let editor = makeBookmarkEditor(
            for: result.bookmark.id,
            heading: result.added ? "Bookmark Added" : "Edit Bookmark",
            showsURL: false
        ) else { return }
        bookmarkEditorPanel.show(editor, below: toolbar.bookmarkAnchor, in: window)
    }

    /// Adds the selected page unless it is bookmarked; returns its bookmark
    /// and whether it is new. Nil on the start page or an empty tab.
    func bookmarkSelectedPage() -> (bookmark: BrowserBookmark, added: Bool)? {
        guard let tab = selectedTab, !tab.isStartPage, let address = tab.webView.url?.absoluteString else {
            return nil
        }
        if let existing = bookmarks.bookmark(url: address) {
            return (existing, false)
        }
        let folder = bookmarks.tree.folderForNewBookmark(lastUsed: manager.bookmarkUIState.lastFolderID)
        let bookmark = bookmarks.addBookmark(url: address, title: tab.displayTitle, to: folder)
        updateChrome()
        return (bookmark, true)
    }

    /// The editor for bookmark or folder `id`, wired to the stores. The
    /// panel shows it; the harness captures it offscreen instead.
    func makeBookmarkEditor(for id: UUID, heading: String, showsURL: Bool) -> BrowserBookmarkEditorView? {
        let tree = bookmarks.tree
        guard let node = tree.node(id: id), let location = tree.location(of: id) else { return nil }
        let isFolder = node.isFolder
        let content = BrowserBookmarkEditorContent(
            heading: heading,
            name: node.folder?.name ?? node.bookmark?.title ?? "",
            namePlaceholder: isFolder ? "Folder name" : "Name",
            url: showsURL ? node.bookmark?.url : nil,
            folderID: location.folderID,
            folders: tree.folderEntries(excluding: isFolder ? id : nil),
            removeTitle: isFolder ? "Delete" : "Remove"
        )
        let editor = BrowserBookmarkEditorView(theme: theme, content: content)
        editor.onFolderChange = { [weak self] folderID in
            guard let self else { return }
            self.bookmarks.move(id, to: folderID, at: 0)
            if !isFolder {
                self.manager.bookmarkUIState.lastFolderID = folderID
            }
        }
        editor.onDone = { [weak self] name, address in
            guard let self else { return }
            self.bookmarkEditorPanel.close(saving: false)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch self.bookmarks.tree.node(id: id) {
            case .folder:
                self.bookmarks.rename(folder: id, to: name)
            case let .bookmark(bookmark):
                let url = address.flatMap(BrowserBookmarkEditorContent.address(from:)) ?? bookmark.url
                self.bookmarks.edit(bookmark: id, title: name, url: url)
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

    /// Opens every bookmark in the folder (subfolders included) in new
    /// tabs and selects the first.
    func openBookmarkFolderInTabs(_ id: UUID) {
        guard let folder = bookmarks.tree.folder(id: id), let first = folder.allBookmarks.first else { return }
        let firstTab = newTab(url: first.url, select: false)
        for bookmark in folder.allBookmarks.dropFirst() {
            newTab(url: bookmark.url, select: false)
        }
        if tabs.contains(where: { $0 === firstTab }) {
            selectTab(id: firstTab.id, focus: true)
        }
    }

    /// Adds "New Folder" in `parentID` at `index`, shows it in the outline
    /// and opens the editor on it to name it.
    func newBookmarkFolder(in parentID: UUID, at index: Int?) {
        let folder = bookmarks.addFolder(name: "New Folder", in: parentID, at: index)
        sidebar.revealBookmarkNode(folder.id)
        guard let window, let anchor = sidebar.anchorView(forBookmarkNode: folder.id),
              let editor = makeBookmarkEditor(for: folder.id, heading: "New Folder", showsURL: false)
        else { return }
        bookmarkEditorPanel.show(editor, below: anchor, in: window)
    }

    /// Edit Bookmark (name, address, folder) or Rename (a folder), under
    /// the row.
    func editBookmarkNodeFromSidebar(_ id: UUID) {
        guard let window, let node = bookmarks.tree.node(id: id) else { return }
        guard let anchor = sidebar.anchorView(forBookmarkNode: id),
              let editor = makeBookmarkEditor(
                  for: id,
                  heading: node.isFolder ? "Rename Folder" : "Edit Bookmark",
                  showsURL: !node.isFolder
              )
        else { return }
        bookmarkEditorPanel.show(editor, below: anchor, in: window)
    }

    /// Deletes a bookmark or an empty folder at once; a folder with
    /// contents asks first.
    func deleteBookmarkNode(_ id: UUID) {
        guard let node = bookmarks.tree.node(id: id) else { return }
        guard let folder = node.folder, !folder.children.isEmpty else {
            bookmarks.remove(id: id)
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
            self?.bookmarks.remove(id: id)
        }
    }
}
