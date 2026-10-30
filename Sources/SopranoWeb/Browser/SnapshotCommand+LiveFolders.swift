import AppKit

/// Snapshot flags for live folders (GitHub pull requests). The harness
/// never runs `gh` unless `--live-fetch gh` says so:
/// - `--live-folder "<name>|<owner/repo|link|query>"` (repeatable): a live
///   folder at the end of Default's Space's top level, before the first
///   window.
/// - `--live-fetch <file|gh|signed-out|no-gh>`: what a fetch answers — the
///   JSON array `gh` would print, read from a file (every folder gets it),
///   the real `gh`, or the signed-out / missing-`gh` failure. Without it
///   every fetch answers "not fetched in the harness".
/// - `--live-refresh`: fetches every live folder after the first window
///   and waits (up to 40 s).
/// - `--live-open <title>`: opens the pull request row titled so (the
///   rail's click) and prints the selected tab.
/// - `--live-folder-editor new|<name>`: the pin editor for a new live
///   folder or an existing one, filled, drawn over the page.
/// - `--print-live-folders`: `browser live-folders`' lines as
///   `live-folders:`, then each live folder row's tooltip and count as
///   `live-row:`.
struct SnapshotLiveFolderOptions {
    static let flags: Set<String> = [
        "--live-folder", "--live-fetch", "--live-refresh", "--live-open", "--live-folder-editor", "--print-live-folders",
    ]
    static let usage = """
                               [--live-folder "<name>|<owner/repo|query>"]... [--live-fetch <file|gh|signed-out|no-gh>]
                               [--live-refresh] [--live-open <title>] [--live-folder-editor new|<name>] [--print-live-folders]
    """

    var folders: [(name: String, source: BrowserLiveFolderSource)] = []
    var fetch: String?
    var refresh = false
    var open: String?
    var editor: String?
    var print = false

    mutating func parse(_ flag: String, value: () throws -> String) throws {
        switch flag {
        case "--live-folder":
            let text = try value()
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let source = BrowserLiveFolderSource.parse(parts[1]) else {
                throw SnapshotCommand.OptionError.unknownOption("\(flag) \(text)")
            }
            folders.append((parts[0], source))
        case "--live-fetch": fetch = try value()
        case "--live-refresh": refresh = true
        case "--live-open": open = try value()
        case "--live-folder-editor": editor = try value()
        default: print = true
        }
    }

    /// Before the first window: the folders, and what a fetch answers.
    @MainActor
    func prepare(_ manager: BrowserWindowManager) {
        manager.liveFolders.fetch = fetcher()
        guard let spaceID = manager.spaces.space(ofProfile: BrowserProfile.defaultID)?.id else { return }
        for folder in folders {
            manager.spaces.addLiveFolder(name: folder.name, source: folder.source, inSpace: spaceID)
        }
    }

    private func fetcher() -> BrowserLiveFolders.Fetch {
        switch fetch {
        case "gh"?:
            return BrowserGitHubCLI.fetch
        case "signed-out"?:
            return { _ in .failure(.signedOut) }
        case "no-gh"?:
            return { _ in .failure(.ghMissing) }
        case let path?:
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            return { source in
                do {
                    return .success(try BrowserPullRequest.decode(data, source: source))
                } catch {
                    return .failure(.failed("The --live-fetch file isn't gh's JSON."))
                }
            }
        case nil:
            return { _ in .failure(.failed("Not fetched in the harness.")) }
        }
    }

    /// After the first window (and the pin flags): fetch, open, print.
    @MainActor
    func run(controller: BrowserWindowController, wait: (TimeInterval) -> Void) {
        let live = controller.manager.liveFolders
        if refresh {
            live.refreshAll()
            let deadline = Date().addingTimeInterval(40)
            while live.states.values.contains(where: \.isLoading), Date() < deadline {
                wait(0.05)
            }
        }
        if let open {
            let rows = controller.railOutlineRows
            if let row = rows.first(where: { $0.node.pin?.displayTitle == open && live.isItem($0.node.id) }) {
                let before = controller.visibleTabs.count
                controller.openPin(row.node.id)
                wait(0.2)
                let tab = controller.selectedTab
                Swift.print("live-open: \(open) -> \(tab?.origin == .today ? "today" : "linked") tab <\(tab?.item.url?.absoluteString ?? tab?.state.url ?? "?")> | tabs \(before) -> \(controller.visibleTabs.count)")
            } else {
                Swift.print("live-open: no pull request row titled \(open) (expand its folder)")
            }
        }
        if print {
            controller.updateRail()
            for line in BrowserLiveFolderCommands.list(controller.manager).split(separator: "\n") {
                Swift.print("live-folders: \(line)")
            }
            for row in controller.verticalTabsView.pinsView.rows where row.row.node.folder?.isLive == true {
                let count = row.row.node.folder?.allPins.count ?? 0
                Swift.print("live-row: \(row.row.node.title) | count \(row.liveFailed ? "!" : "\(count)") | expanded \(row.row.isExpanded) | status \(row.liveStatus ?? "-")")
            }
        }
    }

    /// `--live-folder-editor`: the editor as New Live Folder… or Edit Live
    /// Folder… builds it, drawn over the page under the rail's row.
    @MainActor
    func makeEditor(controller: BrowserWindowController) -> NSView? {
        guard let editor else { return nil }
        let view: BrowserPinEditorView?
        let anchorID: UUID
        if editor == "new" {
            view = controller.makeLiveFolderEditor(editing: nil, parentID: BrowserPinTree.rootID, index: nil)
            anchorID = BrowserPinTree.rootID
        } else {
            let id = controller.currentPinTree.liveFolders().first {
                controller.currentPinTree.folder(id: $0.id)?.name == editor
            }?.id
            view = id.flatMap { controller.makeLiveFolderEditor(editing: $0, parentID: nil, index: nil) }
            anchorID = id ?? BrowserPinTree.rootID
        }
        guard let view else {
            Swift.print("live-editor: no live folder named \(editor)")
            return nil
        }
        let root = controller.rootView
        view.translatesAutoresizingMaskIntoConstraints = true
        view.layoutSubtreeIfNeeded()
        let anchor = controller.pinAnchorView(anchorID)
        let anchorRect = anchor.convert(anchor.bounds, to: root)
        view.frame = BrowserPinEditorView.frame(size: view.fittingSize, below: anchorRect, within: root.bounds)
        root.addSubview(view, positioned: .above, relativeTo: nil)
        view.layoutSubtreeIfNeeded()
        Swift.print("live-editor: \(view.content.heading) | name \(view.nameField.stringValue) | source \(view.content.url ?? "-") | placeholder \(view.content.urlPlaceholder)")
        return view
    }
}
