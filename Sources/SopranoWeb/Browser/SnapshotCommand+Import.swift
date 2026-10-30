import AppKit

/// Import and export flags for `SopranoWeb snapshot`. Imports run after the
/// first window opens and before every other action, into the harness's
/// support folder (a temporary one, or `--support-dir`); sources are only
/// read (Chromium History opens `immutable`).
///
/// - `--import-arc [dir]` (default `~/Library/Application Support/Arc`),
///   `--import-chrome <dir>`, `--import-brave <dir>`, `--import-edge <dir>`,
///   `--import-vivaldi <dir>`, `--import-chromium <dir>` (a Chromium
///   browser's user-data folder),
///   `--import-safari <zip>`, `--import-html <file>` (repeatable, in
///   order): each prints `import-plan:` (one JSON line: each source
///   profile's home Space, Spaces with counts and create/skip/take-over,
///   favorites, Archive, History visits per home, rules, totals), applies
///   the plan as the sheet checks it by default and prints
///   `import-result:` (what was made, History added/skipped and seconds
///   per Space).
/// - `--import-space <name>`: any import but Arc's
///   goes into that Space (the sheet's Space menu) instead of the
///   window's.
/// - `--import-plan`: plans only, applies nothing.
/// - `--import-sheet [checklist|progress|result]`: File ▸ Import Browser
///   Data… on the window, on the first source flag (else the first source
///   found), captured with its checklist, mid-import (30% of History) or
///   finished; prints `import-sheet:` lines.
/// - `--export-pins <file>` / `--export-all-pins <file>`: File ▸ Export
///   Pinned Tabs… for the window's Space / every Space; prints the counts
///   the file reads back as.
/// - `--open-link <url>` (repeatable): a link from another app (a matching
///   rule, else Settings ▸ Links from other apps ▸ "Open links from other
///   apps in"); prints the window, its role (`normal`/`little`) and Space,
///   and the route taken.
/// - `--outside-links little|recent`: sets "Open links from other apps
///   in" (Little Arc / the most recent window) before the links open.
/// - `--link-routing-sheet`: captures Settings ▸ Links from other apps.
struct SnapshotImportOptions {
    enum SheetStage: String {
        case checklist
        case progress
        case result
    }

    var requests: [BrowserImportLoader.Request] = []
    var planOnly = false
    var sheet: SheetStage?
    var exports: [(url: URL, allSpaces: Bool)] = []
    var openLinks: [String] = []
    var outsideLinks: BrowserOutsideLinkDestination?
    var showsLinkRoutingSheet = false
    /// `--import-from-private`: the import runs from a new private window.
    var fromPrivateWindow = false
    /// `--import-space`: the Space a non-Arc import goes into.
    var targetSpace: String?

    static let flags: Set<String> = [
        "--import-arc", "--import-chrome", "--import-brave", "--import-edge", "--import-vivaldi", "--import-chromium",
        "--import-safari", "--import-html", "--import-plan", "--import-sheet",
        "--export-pins", "--export-all-pins", "--open-link", "--link-routing-sheet", "--import-from-private",
        "--import-space", "--outside-links",
    ]

    static let usage = """
                               [--import-arc [dir]] [--import-chrome|brave|edge|vivaldi|chromium <dir>] [--import-safari <zip>]
                               [--import-html <file>] [--import-plan] [--import-sheet [checklist|progress|result]]
                               [--export-pins <file>] [--export-all-pins <file>] [--open-link <url>]...
                               [--link-routing-sheet] [--import-from-private] [--import-space <name>]
                               [--outside-links little|recent]
    """

    var isActive: Bool {
        !requests.isEmpty || sheet != nil || !exports.isEmpty || !openLinks.isEmpty || showsLinkRoutingSheet
            || outsideLinks != nil
    }

    /// `peek` is the next argument (for optional values), `skip` consumes it.
    mutating func parse(
        _ option: String,
        value: () throws -> String,
        peek: () -> String?,
        skip: () -> Void
    ) throws {
        func optional() -> String? {
            guard let next = peek(), !next.hasPrefix("--") else { return nil }
            skip()
            return next
        }
        func file(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        switch option {
        case "--import-arc":
            requests.append(.arc(optional().map(file) ?? BrowserArcImportReader.defaultSupportDirectory))
        case "--import-safari":
            requests.append(.safari(file(try value())))
        case "--import-html":
            requests.append(.html(file(try value())))
        case "--import-plan":
            planOnly = true
        case "--import-sheet":
            let raw = optional() ?? SheetStage.checklist.rawValue
            guard let stage = SheetStage(rawValue: raw) else {
                throw SnapshotCommand.OptionError.unknownOption("--import-sheet \(raw)")
            }
            sheet = stage
        case "--export-pins":
            exports.append((file(try value()), false))
        case "--export-all-pins":
            exports.append((file(try value()), true))
        case "--open-link":
            openLinks.append(try value())
        case "--import-from-private":
            fromPrivateWindow = true
        case "--import-space":
            targetSpace = try value()
        case "--outside-links":
            let raw = try value()
            switch raw {
            case "little": outsideLinks = .littleArc
            case "recent": outsideLinks = .mostRecentWindow
            default: throw SnapshotCommand.OptionError.unknownOption("--outside-links \(raw)")
            }
        case "--link-routing-sheet":
            showsLinkRoutingSheet = true
        default:
            // `--import-chrome|brave|edge|vivaldi|chromium <dir>`.
            guard option.hasPrefix("--import-"),
                  let browser = BrowserImportSourceKind(rawValue: String(option.dropFirst("--import-".count))),
                  browser.isChromium
            else { throw SnapshotCommand.OptionError.unknownOption(option) }
            requests.append(.chromium(browser, file(try value())))
        }
    }

    /// What the import step leaves for the capture.
    @MainActor
    struct Outcome {
        var sheet: BrowserImportSheet?
        /// The sheet drawn the moment the stage was reached (progress
        /// keeps moving afterwards).
        var frozen: NSImage?
        var linkRoutingSheet: BrowserLinkRoutingSheet?

        var window: NSWindow? { linkRoutingSheet?.window ?? sheet?.window }
    }

    @MainActor
    func run(manager: BrowserWindowManager, controller normal: BrowserWindowController) -> Outcome {
        var outcome = Outcome()
        let controller = fromPrivateWindow ? manager.newPrivateWindow() : normal
        if let stage = sheet {
            outcome.sheet = runSheet(stage, manager: manager, controller: controller, frozen: &outcome.frozen)
        } else {
            for request in requests {
                runImport(request, manager: manager, controller: controller)
            }
        }
        for export in exports {
            exportPins(export.url, allSpaces: export.allSpaces, controller: controller)
        }
        if let outsideLinks {
            manager.linkRouting.setOtherLinks(outsideLinks)
            print("outside-links: \(outsideLinks.title)")
        }
        for link in openLinks {
            openLink(link, manager: manager)
        }
        if showsLinkRoutingSheet {
            let routingSheet = manager.makeLinkRoutingSheet()
            routingSheet.dump.forEach { print("link-routing: \($0)") }
            if manager.linkRouting.rules.isEmpty { print("link-routing: no rules") }
            outcome.linkRoutingSheet = routingSheet
        }
        return outcome
    }

    /// Lets a sheet's import finish (cancelling a mid-import capture's)
    /// before the harness removes anything.
    @MainActor
    static func finish(_ outcome: Outcome) {
        guard let sheet = outcome.sheet, sheet.state == .importing else { return }
        sheet.cancelImport()
        spin(until: 120) { sheet.state != .importing }
        print("import-sheet: after capture \(sheet.statusText)")
    }

    // MARK: Steps

    @MainActor
    private func runImport(_ request: BrowserImportLoader.Request, manager: BrowserWindowManager, controller: BrowserWindowController) {
        let data: BrowserImportSourceData
        let readStart = Date()
        do {
            data = try BrowserImportLoader.read(request, historyCutoff: manager.importHistoryCutoff)
        } catch {
            print("import-plan: error \(error)")
            return
        }
        var plan = BrowserImportPlanner.plan(for: data, context: manager.importContext(for: controller))
        if let id = targetSpaceID(in: manager) {
            BrowserImportPlanner.retarget(&plan, to: id, spaces: manager.spaces.list)
        }
        print(String(format: "import-read: %@ %.2f s", request.kind.rawValue, Date().timeIntervalSince(readStart)))
        print("import-plan: \(Self.json(Self.planObject(plan)))")
        guard !planOnly else { return }
        let state = RunState()
        let started = Date()
        manager.runImport(
            plan,
            in: controller,
            cancellation: BrowserImportCancellation(),
            progress: { progress in
                let percent = Int(progress.fraction * 100)
                guard percent / 25 != state.lastPrinted / 25 else { return }
                state.lastPrinted = percent
                print("import-progress: \(percent)% \(progress.handled)/\(progress.total) \(progress.item)")
            },
            completion: { state.summary = $0 }
        )
        Self.spin(until: 1_800) { state.summary != nil }
        guard let finished = state.summary else {
            print("import-result: timed out")
            return
        }
        print("import-result: \(Self.json(Self.resultObject(finished, seconds: Date().timeIntervalSince(started))))")
        for (spaceID, links, splits) in finished.todayTabs {
            let holders = manager.controllers.filter { window in window.tabs.contains { $0.spaceID == spaceID } }
            let tabs = holders.reduce(0) { total, window in total + window.tabs.filter { $0.spaceID == spaceID }.count }
            let kinds = holders.map { $0.kind.isPrivate ? "private" : "normal" }.joined(separator: ",")
            let shown = holders.contains { $0.currentSpaceID == spaceID } ? "shown" : "hidden"
            let made = holders.flatMap { window in
                window.splits.filter { split in window.tabs.contains { $0.id == split.focusedTabID && $0.spaceID == spaceID } }
            }
            print("import-today: \(links.count) imported, \(tabs) tabs of the Space in \(holders.count) window(s) [\(kinds)], "
                + "Space \(shown), \(splits.count) Arc split view(s) -> \(made.count) split(s) "
                + "[\(made.map { String($0.tabIDs.count) }.joined(separator: ","))]")
        }
        for history in finished.history {
            print(String(
                format: "import-history: %@ -> %@ added %d skipped %d in %.2f s%@",
                history.id, history.spaceName, history.count.added, history.count.skipped, history.seconds,
                history.error.map { " error \($0)" } ?? ""
            ))
        }
    }

    /// `--import-space`'s Space, by name.
    @MainActor
    private func targetSpaceID(in manager: BrowserWindowManager) -> UUID? {
        guard let targetSpace else { return nil }
        let id = manager.spaces.spaces.first { $0.displayName == targetSpace }?.id
        if id == nil {
            print("import-space: no Space \(targetSpace)")
        }
        return id
    }

    /// A harness import's callbacks' state.
    @MainActor
    private final class RunState {
        var summary: BrowserImporter.Summary?
        var lastPrinted = -1
    }

    @MainActor
    private func runSheet(
        _ stage: SheetStage,
        manager: BrowserWindowManager,
        controller: BrowserWindowController,
        frozen: inout NSImage?
    ) -> BrowserImportSheet {
        var detected = BrowserImportLoader.detected()
        for request in requests {
            detected.removeAll { $0.kind == request.kind }
        }
        detected = requests.filter { $0.kind == .arc || $0.kind.isChromium } + detected
        let sheet = BrowserImportSheet(manager: manager, controller: controller, detected: detected)
        if let request = requests.first {
            sheet.select(request)
        }
        Self.spin(until: 120) { sheet.state != .loading }
        if let id = targetSpaceID(in: manager) {
            sheet.chooseTarget(id)
        }
        if stage != .checklist, sheet.state == .ready {
            sheet.startImport()
            if stage == .progress {
                Self.spin(until: 1_800) {
                    sheet.state != .importing || (sheet.progress?.fraction ?? 0) >= 0.3
                }
                frozen = Self.image(of: sheet.window)
            } else {
                Self.spin(until: 1_800) { sheet.state != .importing }
            }
        }
        print("import-sheet: state \(sheet.state) | \(sheet.statusText)")
        sheet.dump.forEach { print("import-sheet: \($0)") }
        return sheet
    }

    @MainActor
    private func exportPins(_ url: URL, allSpaces: Bool, controller: BrowserWindowController) {
        do {
            try controller.exportPinnedTabs(to: url, allSpaces: allSpaces)
        } catch {
            print("export-pins: error \(error)")
            return
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let nodes = BrowserNetscapeBookmarks.parse(data: data)
        let counts = BrowserImportPlanner.nodeCounts(nodes)
        print("export-pins: \(url.lastPathComponent) \(data.count) bytes, reads back as \(counts.pins) pins in \(counts.folders) folders\(allSpaces ? " (every Space)" : "")")
    }

    @MainActor
    private func openLink(_ link: String, manager: BrowserWindowManager) {
        guard let url = URL(string: link) else {
            print("open-link: bad URL \(link)")
            return
        }
        let route = manager.outsideLinkRoute(for: url)
        manager.open([url])
        let window = manager.activeController
        let number = window.flatMap { manager.controllers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let space = window.flatMap(manager.space(of:))?.displayName ?? "-"
        let routeText = switch route {
        case let .rule(rule): "rule \(rule.match.rawValue) \(rule.value)"
        case .littleArc: "no rule: Little Arc"
        case .mostRecentWindow: "no rule: most recent window"
        }
        let role = window?.role.rawValue ?? "-"
        print("open-link: \(link) -> window \(number) (\(role)), Space \(space) (\(routeText)), \(window?.visibleTabs.count ?? 0) tabs")
    }

    // MARK: Output

    static func planObject(_ plan: BrowserImportPlan) -> [String: Any] {
        let profiles: [[String: Any]] = plan.profiles.map { profile in
            let target: String = switch profile.target {
            case .existing: "existing"
            case .new: "new"
            }
            return [
                "key": profile.key, "name": profile.displayName, "home": target, "homeName": plan.homeName(ofProfile: profile.key),
                "homeTakenOver": profile.adoptableSpaceID != nil && plan.firstNewSpace(ofProfile: profile.key) != nil,
            ]
        }
        let spaces: [[String: Any]] = plan.spaces.map { space in
            let action = space.isSkipped
                ? "skip (imported before)"
                : (space.isIncluded ? (plan.adoptedSpaceID(by: space) != nil ? "take over home" : "create") : "unchecked")
            return [
                "name": space.name,
                "profile": space.profileKey,
                "color": space.color.rawValue,
                "pins": space.pinCount,
                "folders": space.folderCount,
                "today": space.today.count,
                "action": action,
            ]
        }
        let favorites: [[String: Any]] = plan.favorites.map { favorites in
            [
                "profile": favorites.profileKey,
                "new": favorites.links.count,
                "toFavorites": favorites.toFavorites,
                "overflowPinned": favorites.overflow,
                "alreadyThere": favorites.alreadyThere,
            ]
        }
        let folders: [[String: Any]] = plan.folders.map { folder in
            ["name": folder.name, "pins": folder.pinCount, "folders": folder.folderCount, "skip": folder.alreadyThere]
        }
        let history: [[String: Any]] = plan.history.map { history in
            [
                "id": history.id, "title": history.title, "visits": history.visitCount, "checked": history.isIncluded,
                "sourceVisits": history.sourceVisitCount, "olderThanRetention": history.olderCount,
            ]
        }
        let pins: Int = plan.spaces.reduce(0) { $0 + $1.pinCount } + plan.folders.reduce(0) { $0 + $1.pinCount }
        let folderCount: Int = plan.spaces.reduce(0) { $0 + $1.folderCount } + plan.folders.reduce(0) { $0 + $1.folderCount }
        let totals: [String: Int] = [
            "spaces": plan.spaces.count,
            "spacesToCreate": plan.spaces.filter { $0.isIncluded && !$0.isSkipped }.count,
            "spacesSkipped": plan.spaces.filter(\.isSkipped).count,
            "pins": pins,
            "folders": folderCount,
            "today": plan.spaces.reduce(0) { $0 + $1.today.count },
            "favorites": plan.favorites.reduce(0) { $0 + $1.links.count + $1.alreadyThere },
            "favoritesNew": plan.favorites.reduce(0) { $0 + $1.links.count },
            "archive": plan.archive?.items.count ?? 0,
            "archiveNew": plan.archive?.newCount ?? 0,
            "rules": plan.routing?.importable ?? 0,
            "visits": plan.history.reduce(0) { $0 + $1.visitCount },
            "visitsChecked": plan.includedVisitCount,
        ]
        var object: [String: Any] = [
            "source": plan.source.rawValue,
            "sourceName": plan.sourceName,
            "sourceProfiles": profiles,
            "spaces": spaces,
            "favorites": favorites,
            "folders": folders,
            "history": history,
            "totals": totals,
            "summary": BrowserImportChecklist.summary(of: plan),
            "targetSpace": plan.targetSpaceID?.uuidString ?? NSNull(),
        ]
        if let archive = plan.archive {
            object["archive"] = ["items": archive.items.count, "new": archive.newCount, "withoutSpace": archive.spacelessCount]
        }
        if let routing = plan.routing {
            object["routing"] = ["rules": routing.rules.count, "importable": routing.importable, "unsupported": routing.unsupported]
        }
        return object
    }

    static func resultObject(_ summary: BrowserImporter.Summary, seconds: Double) -> [String: Any] {
        [
            "spacesCreated": summary.spacesCreated,
            "spacesSkipped": summary.spacesSkipped,
            "pinsAdded": summary.pinsAdded,
            "foldersAdded": summary.foldersAdded,
            "favoritesAdded": summary.favoritesAdded,
            "favoritesPinned": summary.favoritesPinned,
            "archiveAdded": summary.archiveAdded,
            "faviconsAdded": summary.faviconsAdded,
            "rulesAdded": summary.rulesAdded,
            "todayTabs": summary.todayTabs.reduce(0) { $0 + $1.links.count },
            "visitsAdded": summary.visitsAdded,
            "visitsSkipped": summary.visitsSkipped,
            "cancelled": summary.cancelled,
            "seconds": (seconds * 100).rounded() / 100,
        ]
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func image(of window: NSWindow?) -> NSImage? {
        guard let content = window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Runs the loop until `done` or `seconds` pass.
    @MainActor
    private static func spin(until seconds: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
    }
}
