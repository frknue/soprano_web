import AppKit

/// Archive flags for `SopranoWeb snapshot`, run in order with the session
/// actions on the active window, through the handlers the menu, a click
/// and the Edit Space sheet call:
///
/// - `--archive-today`: ⇧⌘K (Spaces ▸ Archive Today Tabs).
/// - `--restore-archived <n|title>`: a click on the Archive row n (1-based,
///   in the order the sidebar's Archive lists the active window's
///   Space, under its search) or the first one titled so (or whose title
///   contains it).
/// - `--archive-search <text>`: shows the sidebar's Archive and types into
///   its search field; prints every row it lists.
/// - `--archive-after <choice>[:<space>]`: Edit Space ▸ "Archive Today
///   tabs after" for the Space (the active window's without one), picked
///   from the sheet's menu and saved; `never`, `days30`, `days7`,
///   `hours24`, `hours12`, `hours6`, `hour1`.
/// - `--print-archive`: one `archive:` JSON line: every entry (title,
///   address, Space, the Space whose data holds it, reason, time), newest
///   first, and `archive.json`'s version and entry count.
///
/// `--sidebar archive` seeds a few entries over several days into the
/// Default Space when the Archive is empty, as `--sidebar` seeds History.
enum SnapshotArchiveAction {
    case archiveToday
    case restore(String)
    case search(String)
    case archiveAfter(BrowserArchiveAfter, space: String?)
    case printArchive
    /// `--archive-seed <n>`: n entries through the importers' `insert`.
    case seed(Int)
    /// `--archive-batch <n>`: n more archived in one `archive(_:)` call,
    /// as ⇧⌘K and the idle pass write.
    case batch(Int)

    static let flags: Set<String> = [
        "--archive-today", "--restore-archived", "--archive-search", "--archive-after", "--print-archive",
        "--archive-seed", "--archive-batch",
    ]

    static let usage = """
                               [--archive-today] [--restore-archived <n|title>] [--archive-search <text>]
                               [--archive-after <choice>[:<space>]] [--print-archive]
                               [--archive-seed <n>] [--archive-batch <n>]
    """

    /// Nil when `option` is not one of these flags.
    static func parse(_ option: String, value: () throws -> String) throws -> SnapshotArchiveAction? {
        switch option {
        case "--archive-today": return .archiveToday
        case "--restore-archived": return .restore(try value())
        case "--archive-search": return .search(try value())
        case "--archive-after":
            let raw = try value()
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            guard let choice = parts.first.flatMap(BrowserArchiveAfter.init(rawValue:)) else {
                throw SnapshotCommand.OptionError.unknownOption("--archive-after \(raw)")
            }
            return .archiveAfter(choice, space: parts.count > 1 ? parts[1] : nil)
        case "--print-archive": return .printArchive
        case "--archive-seed", "--archive-batch":
            let raw = try value()
            guard let count = Int(raw), count > 0 else {
                throw SnapshotCommand.OptionError.unknownOption("\(option) \(raw)")
            }
            return option == "--archive-seed" ? .seed(count) : .batch(count)
        default: return nil
        }
    }

    @MainActor
    func perform(in manager: BrowserWindowManager) {
        if case .printArchive = self {
            print(Self.archiveJSON(manager))
            return
        }
        if case let .seed(count) = self {
            let entries = Self.syntheticEntries(count, manager: manager, prefix: "seed")
            let start = Date()
            let added = manager.archive.insert(entries, reason: .imported)
            print(String(format: "archive-seed: %d inserted in %.3f s (Archive %d)", added, Date().timeIntervalSince(start), manager.archive.entries.count))
            return
        }
        if case let .batch(count) = self {
            let entries = Self.syntheticEntries(count, manager: manager, prefix: "batch")
            let start = Date()
            let added = manager.archive.archive(entries)
            print(String(format: "archive-batch: %d archived in %.3f s, one write (Archive %d, search “batch 1999”: %d)",
                         added.count, Date().timeIntervalSince(start), manager.archive.entries.count,
                         manager.archive.search("batch 1999", inProfile: BrowserProfile.defaultID).count))
            return
        }
        guard let controller = manager.activeController else {
            print("snapshot: no window is open")
            return
        }
        switch self {
        case .archiveToday:
            let before = controller.tabs.count
            let start = Date()
            let archived = controller.archiveTodayTabs()
            let seconds = Date().timeIntervalSince(start)
            let today = controller.visibleTabs.filter { $0.origin == .today }.map(SnapshotRailAction.describe)
            print(String(format: "archive-today: %d tab(s) archived in %.3f s (Archive %d)", archived.count, seconds, manager.archive.entries.count))
            print("archive-today: \(Self.describe(archived)) | tabs \(before) -> \(controller.tabs.count) | Today left \(today)")
        case let .restore(key):
            let sidebar = controller.sidebar
            if !controller.isSidebarVisible || sidebar.section != .archive {
                controller.showSidebar(section: .archive)
            }
            let listed = sidebar.listedArchiveEntries
            let entry = Int(key).flatMap { listed.indices.contains($0 - 1) ? listed[$0 - 1] : nil }
                ?? listed.first { $0.displayTitle == key }
                ?? listed.first { $0.displayTitle.localizedCaseInsensitiveContains(key) }
            guard let entry else {
                print("restore-archived: no Archive row \(key) (\(listed.count) listed)")
                return
            }
            let fromSpace = Self.spaceName(controller.currentSpaceID, in: manager)
            sidebar.clickArchiveRow(entry.id)
            let target = manager.activeController ?? controller
            let selected = target.selectedTab
            let number = (manager.controllers.firstIndex { $0 === target } ?? -1) + 1
            print("restore-archived: \(entry.displayTitle) <\(entry.url)> from Space \(Self.spaceName(entry.spaceID, in: manager)) | window \(number) Space \(fromSpace) -> \(Self.spaceName(target.currentSpaceID, in: manager)) | selected \(selected.map(SnapshotRailAction.describe) ?? "-") | still archived: \(manager.archive.entry(id: entry.id) != nil)")
        case let .search(text):
            if !controller.isSidebarVisible || controller.sidebar.section != .archive {
                controller.showSidebar(section: .archive)
            }
            controller.sidebar.setSearchText(text)
            let listed = controller.sidebar.listedArchiveEntries
            for entry in listed {
                print("archive-search: \(entry.displayTitle) — \(entry.host) [\(Self.spaceName(entry.spaceID, in: manager))]")
            }
            print("archive-search: \(text) -> \(listed.count) shown")
        case let .archiveAfter(choice, spaceName):
            let space = spaceName.map { name in manager.spaces.spaces.first { $0.displayName == name } }
                ?? controller.currentSpaceID.flatMap(manager.spaces.space(id:))
            guard let space else {
                print("archive-after: no Space \(spaceName ?? "-")")
                return
            }
            // What picking the choice in Edit Space and saving runs.
            let sheet = controller.makeSpaceSheet(editing: space.id)
            guard let item = sheet.archiveAfterMenu().items.first(where: { $0.title == choice.title }) else {
                print("archive-after: no choice \(choice.title)")
                return
            }
            sheet.archiveAfterChosen(item)
            sheet.savePressed()
            let saved = manager.profiles.profile(id: space.profileID)?.archiveAfter
            print("archive-after: \(space.displayName) -> \(saved?.rawValue ?? "-") (\(saved?.title ?? "-"))")
        case .printArchive, .seed, .batch:
            break
        }
    }

    /// `count` distinct Default Space entries, newest first, over the last
    /// days, titled "<prefix> <n>".
    @MainActor
    static func syntheticEntries(_ count: Int, manager: BrowserWindowManager, prefix: String) -> [BrowserArchiveEntry] {
        let spaceID = manager.spaces.space(ofProfile: BrowserProfile.defaultID)?.id
        let now = manager.tabSleeper.now()
        return (0..<count).map { index in
            BrowserArchiveEntry(
                url: "https://\(prefix).example/page/\(index)",
                title: "\(prefix) \(index)",
                spaceID: spaceID,
                profileID: BrowserProfile.defaultID,
                archivedAt: now.addingTimeInterval(-Double(index) * 60),
                reason: .auto,
                faviconKey: nil
            )
        }
    }

    @MainActor
    static func spaceName(_ id: UUID?, in manager: BrowserWindowManager) -> String {
        id.flatMap(manager.spaces.space(id:))?.displayName ?? "-"
    }

    /// "title <url> (reason, time)" per entry.
    @MainActor
    static func describe(_ entries: [BrowserArchiveEntry]) -> [String] {
        entries.map { "\($0.displayTitle) <\($0.url)> (\($0.reason.rawValue), \($0.archivedAt.ISO8601Format()))" }
    }

    /// The Archive as one JSON line.
    @MainActor
    static func archiveJSON(_ manager: BrowserWindowManager) -> String {
        let entries: [[String: Any]] = manager.archive.entries.map { entry in
            [
                "title": entry.displayTitle,
                "url": entry.url,
                "space": spaceName(entry.spaceID, in: manager),
                "dataSpace": manager.spaces.space(ofProfile: entry.profileID)?.displayName ?? entry.profileID.uuidString,
                "reason": entry.reason.rawValue,
                "archivedAt": entry.archivedAt.ISO8601Format(),
                "faviconKey": entry.faviconKey ?? NSNull(),
            ]
        }
        let file = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manager.archive.url))) as? [String: Any]
        let object: [String: Any] = [
            "count": entries.count,
            "entries": entries,
            "file": [
                "version": file?["version"] ?? NSNull(),
                "entries": (file?["entries"] as? [Any])?.count ?? NSNull(),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return "archive: " + String(decoding: data, as: UTF8.self)
    }

    /// `--sidebar archive` on an empty Archive: entries over today,
    /// yesterday, earlier this week and an older day, in the Default
    /// Space.
    @MainActor
    static func seed(_ archive: BrowserArchiveStore, spaces: BrowserSpaceStore, now: Date, calendar: Calendar = .current) {
        guard archive.entries.isEmpty else { return }
        let spaceID = spaces.defaultSpace?.id
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start) ?? start
        }
        let samples: [(String, String, Date)] = [
            ("https://webkit.org/blog/", "WebKit Blog", min(now.addingTimeInterval(-600), day(0, hour: 23))),
            ("https://www.procope.com/", "Café Procope — Menu", min(now.addingTimeInterval(-3_600), day(0, hour: 22))),
            ("https://developer.apple.com/documentation/webkit/wkwebview", "WKWebView | Apple Developer Documentation", day(1, hour: 16, minute: 20)),
            ("https://www.swift.org/documentation/", "Documentation | Swift.org", day(1, hour: 10, minute: 5)),
            ("https://news.ycombinator.com/", "Hacker News", day(3, hour: 18, minute: 45)),
            ("https://en.wikipedia.org/wiki/Caf%C3%A9", "Café - Wikipedia", day(12, hour: 9, minute: 30)),
        ]
        let entries = samples.enumerated().map { index, sample in
            BrowserArchiveEntry(
                url: sample.0,
                title: sample.1,
                spaceID: spaceID,
                profileID: BrowserProfile.defaultID,
                archivedAt: sample.2,
                reason: index.isMultiple(of: 2) ? .auto : .manual,
                faviconKey: BrowserFaviconSelection.key(for: URL(string: sample.0))
            )
        }
        // `insert` (the importers' path) sets one reason per call.
        for reason in [BrowserArchiveReason.auto, .manual] {
            archive.insert(entries.filter { $0.reason == reason }, reason: reason)
        }
    }
}
