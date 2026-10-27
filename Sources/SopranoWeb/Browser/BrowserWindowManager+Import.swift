import AppKit

/// File ▸ Import Browser Data… and File ▸ Export Pinned Tabs…, and
/// Settings ▸ Links from other apps: the manager's side of imports.
extension BrowserWindowManager {
    /// What a plan compares the source with; `controller`'s current Space
    /// is where bookmark folders go (Default's first Space without one).
    func importContext(for controller: BrowserWindowController?) -> BrowserImportPlanner.Context {
        BrowserImportPlanner.Context(
            profiles: profiles.profiles,
            spaces: spaces.list,
            archiveIDs: Set(archive.entries.map(\.id)),
            routingRules: linkRouting.rules,
            targetSpaceID: controller?.pinSpaceID ?? spaces.firstSpace(ofProfile: BrowserProfile.defaultID)?.id,
            historyCutoff: importHistoryCutoff
        )
    }

    /// Settings ▸ Remove history items now: an import leaves out what the
    /// retention pass would remove.
    var importHistoryCutoff: Date? {
        settingsStore.settings.historyRetention.cutoff(now: Date())
    }

    var importerStores: BrowserImporter.Stores {
        BrowserImporter.Stores(
            profiles: profiles,
            spaces: spaces,
            archive: archive,
            favicons: faviconStore,
            linkRouting: linkRouting,
            history: { [unowned self] profile in self.history(for: profile) }
        )
    }

    /// Reads `request` off the main thread and plans it against the stores
    /// as they are when the read finishes.
    func planImport(
        _ request: BrowserImportLoader.Request,
        for controller: BrowserWindowController?,
        completion: @escaping @MainActor (Result<BrowserImportPlan, Error>) -> Void
    ) {
        let cutoff = importHistoryCutoff
        Task.detached(priority: .userInitiated) {
            let data = Result { try BrowserImportLoader.read(request, historyCutoff: cutoff) }
            await MainActor.run { [weak self, weak controller] in
                guard let self else { return }
                completion(data.map { BrowserImportPlanner.plan(for: $0, context: self.importContext(for: controller)) })
            }
        }
    }

    /// Applies `plan`. The import's Today tabs join their Spaces unloaded in
    /// `controller` when it shows Spaces, else in the most recent normal
    /// window (a new one when none is open: an import from a private window,
    /// or one whose window closed meanwhile), which switches to the first
    /// imported Space. History follows in the background; `completion`
    /// gets the summary.
    @discardableResult
    func runImport(
        _ plan: BrowserImportPlan,
        in controller: BrowserWindowController?,
        cancellation: BrowserImportCancellation,
        progress: @escaping @MainActor @Sendable (BrowserImporter.Progress) -> Void,
        completion: @escaping @MainActor @Sendable (BrowserImporter.Summary) -> Void
    ) -> BrowserImporter.Summary {
        let importer = BrowserImporter(stores: importerStores)
        let summary = importer.run(plan, cancellation: cancellation, progress: progress, completion: completion)
        guard !summary.todayTabs.isEmpty || summary.firstSpaceID != nil else { return summary }
        let target = controller?.hasSpaces == true
            ? controller
            : (outsideTabbedController.flatMap { $0.hasSpaces ? $0 : nil } ?? newWindow())
        guard let target, target.hasSpaces else { return summary }
        for (spaceID, links) in summary.todayTabs {
            for link in links {
                target.addRestoredTab(BrowserTabState(url: link.url, title: link.title, spaceID: spaceID))
            }
        }
        if let first = summary.firstSpaceID {
            target.switchToSpace(first, focus: false)
        }
        target.updateTabStrip()
        return summary
    }

    /// File ▸ Import Browser Data…, as a sheet on the window.
    func showImportSheet(from controller: BrowserWindowController?) {
        guard let controller = controller ?? tabbedController, let parent = controller.window else {
            newWindow()
            return
        }
        let sheet = importSheet ?? BrowserImportSheet(manager: self, controller: controller)
        importSheet = sheet
        guard let window = sheet.window, window.sheetParent == nil else { return }
        guard !placement.isOffscreen else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.importSheet = nil
        }
    }

    /// Settings ▸ Links from other apps, as a sheet on Settings.
    func showLinkRouting(on parent: NSWindow) {
        let sheet = linkRoutingSheet ?? makeLinkRoutingSheet()
        linkRoutingSheet = sheet
        guard let window = sheet.window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.linkRoutingSheet = nil
        }
    }

    func makeLinkRoutingSheet() -> BrowserLinkRoutingSheet {
        BrowserLinkRoutingSheet(store: linkRouting, spaces: spaces, theme: themeManager.currentTheme)
    }
}

// MARK: - Export

/// File ▸ Export Pinned Tabs…: pins as a Netscape bookmarks file (what
/// Chrome, Firefox and Safari import).
enum BrowserPinExport {
    /// One Space's pins at the top level, or every Space as a top-level
    /// folder named after it.
    static func html(spaces: [BrowserSpace], allSpaces: Bool) -> String {
        let nodes: [BrowserImportedNode]
        if allSpaces {
            nodes = spaces.map { space in
                .folder(BrowserImportedFolder(
                    name: space.displayName,
                    children: BrowserImportPlanner.importedNodes(space.pinned.root.children)
                ))
            }
        } else {
            nodes = spaces.first.map { BrowserImportPlanner.importedNodes($0.pinned.root.children) } ?? []
        }
        let title = allSpaces || spaces.count != 1 ? "Pinned Tabs" : "Pinned Tabs — \(spaces[0].displayName)"
        return BrowserNetscapeBookmarks.html(for: nodes, title: title)
    }
}

extension BrowserWindowController {
    /// File ▸ Export Pinned Tabs…: a save panel whose "All Spaces" switch
    /// exports every Space as a folder instead of this window's Space.
    func exportPinnedTabs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pinned Tabs.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let accessory = BrowserPinExportAccessory(theme: theme)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.exportPinnedTabs(to: url, allSpaces: accessory.allSpaces)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Writes the pins (this window's Space, or every Space) to `url`.
    func exportPinnedTabs(to url: URL, allSpaces: Bool) throws {
        let selected = allSpaces ? spaces.spaces : (pinSpaceID.flatMap(spaces.space(id:)).map { [$0] } ?? [])
        try Data(BrowserPinExport.html(spaces: selected, allSpaces: allSpaces).utf8).write(to: url, options: .atomic)
    }
}

/// The save panel's "Export every Space" checkbox.
@MainActor
final class BrowserPinExportAccessory: NSView {
    private let checkbox: ChromeCheckbox
    private let label = NSTextField(labelWithString: "Export every Space, each as a folder")

    var allSpaces: Bool { checkbox.isChecked }

    init(theme: AppTheme) {
        checkbox = ChromeCheckbox(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        label.font = ChromeFont.label
        label.textColor = theme.colors.textPrimary
        for view in [checkbox, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
