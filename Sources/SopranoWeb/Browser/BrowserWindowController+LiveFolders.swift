import AppKit

/// Live folders in a window: the pinned tree as shown (each live folder
/// with its pull requests), opening a pull request, and New / Edit Live
/// Folder in the pin editor.
extension BrowserWindowController {
    /// The pin Space's tree as the rail, its folder preview and Open All in
    /// Tabs show it. Edits go to `currentPinTree` (the saved tree).
    var displayPinTree: BrowserPinTree {
        manager.liveFolders.display(currentPinTree)
    }

    /// A live folder fetched, failed, started loading, appeared or went.
    func liveFoldersChanged() {
        updateRail()
        syncFolderPreview()
        markStartPagesStale()
    }

    /// A pull request: the current Space's Today tab already on it, else a
    /// new Today tab, selected.
    func openLiveItem(_ item: BrowserPullRequest) {
        if let tab = todayTabs.first(where: { $0.item.url?.absoluteString == item.url || $0.state.url == item.url }) {
            selectTab(id: tab.id, focus: true)
        } else {
            newTab(url: item.url)
        }
    }

    // MARK: - Editor

    /// New Live Folder… from the rail's menu: the pin editor with a name
    /// and the source (`owner/repo`, a repository link or a GitHub search);
    /// Done creates it at `index` in `parentID` and fetches it.
    func newLiveFolder(in parentID: UUID, at index: Int?) {
        guard let window, let editor = makeLiveFolderEditor(editing: nil, parentID: parentID, index: index) else { return }
        bookmarkEditorPanel.show(editor, below: pinAnchorView(parentID), in: window)
    }

    /// Edit Live Folder…: its name, source and folder.
    func editLiveFolder(_ id: UUID) {
        guard let window, let editor = makeLiveFolderEditor(editing: id, parentID: nil, index: nil) else { return }
        bookmarkEditorPanel.show(editor, below: pinAnchorView(id), in: window)
    }

    /// The pin editor for a live folder: `editing` an existing one, or a
    /// new one in `parentID` at `index`. The harness captures it offscreen.
    func makeLiveFolderEditor(editing id: UUID?, parentID: UUID?, index: Int?) -> BrowserPinEditorView? {
        guard let spaceID = pinSpaceID else { return nil }
        let tree = spaces.pinTree(inSpace: spaceID)
        let existing = id.flatMap(tree.folder(id:))
        if id != nil, existing?.isLive != true { return nil }
        var parent = id.flatMap { tree.location(of: $0)?.folderID } ?? parentID ?? BrowserPinTree.rootID
        if tree.folder(id: parent)?.isLive != false {
            parent = BrowserPinTree.rootID
        }
        let content = BrowserPinEditorContent(
            heading: existing == nil ? "New Live Folder" : "Edit Live Folder",
            name: existing?.name ?? "",
            namePlaceholder: "Folder name",
            url: existing?.source?.text ?? "",
            folderID: parent,
            folders: tree.folderEntries(excluding: id),
            removeTitle: existing == nil ? nil : "Delete",
            urlPlaceholder: "owner/repo or a GitHub search"
        )
        let editor = BrowserPinEditorView(theme: theme, content: content)
        var chosenParent = parent
        editor.onFolderChange = { [weak self] folderID in
            chosenParent = folderID
            guard let self, let id else { return }
            self.spaces.movePin(id, to: folderID, at: 0, inSpace: spaceID)
        }
        editor.onDone = { [weak self] name, text in
            guard let self else { return }
            self.bookmarkEditorPanel.close(saving: false)
            // An empty source is a cancel for a new folder and keeps an
            // existing folder's.
            guard let source = text.flatMap(BrowserLiveFolderSource.parse) ?? existing?.source else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? source.defaultName : trimmed
            if let id {
                self.spaces.editLiveFolder(id, name: name, source: source, inSpace: spaceID)
            } else if let folder = self.spaces.addLiveFolder(
                name: name,
                source: source,
                in: chosenParent,
                at: chosenParent == parent ? index : 0,
                inSpace: spaceID
            ) {
                self.manager.pinUIState.setExpanded(true, folder: folder.id)
                self.revealPinNode(folder.id)
                self.manager.liveFolders.refresh(folder.id)
            }
        }
        editor.onRemove = { [weak self] in
            self?.bookmarkEditorPanel.close(saving: false)
            if let id { self?.deleteBookmarkNode(id) }
        }
        editor.onCancel = { [weak self] in
            self?.bookmarkEditorPanel.close(saving: false)
        }
        return editor
    }
}
