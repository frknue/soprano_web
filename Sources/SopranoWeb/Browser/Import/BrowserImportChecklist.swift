import Foundation

/// What the import sheet lists for a plan, pure: one row per item with
/// its section, title, counts and target, whether it is checked and
/// whether it can be; the result's lines after an import.
enum BrowserImportChecklist {
    enum Item: Hashable, Sendable {
        case space(String)
        case favorites(String)
        case archive
        case routing
        case folder(String)
        case history(String)
    }

    struct Row: Equatable, Sendable {
        var item: Item
        var section: String
        var title: String
        var detail: String
        var isChecked: Bool
        var isEnabled: Bool
    }

    static func rows(for plan: BrowserImportPlan) -> [Row] {
        var rows: [Row] = []
        for space in plan.spaces {
            let icon = if case let .emoji(emoji) = space.icon { "\(emoji) " } else { "" }
            var parts = [count(space.pinCount, "pin"), count(space.folderCount, "folder")]
            if !space.today.isEmpty { parts.append(count(space.today.count, "Today tab")) }
            let detail = space.isSkipped
                ? "Imported before; skipped"
                : parts.joined(separator: " · ") + " → \(target(space.profileKey, in: plan))"
            rows.append(Row(
                item: .space(space.id),
                section: "Spaces",
                title: icon + space.name,
                detail: detail,
                isChecked: space.isIncluded && !space.isSkipped,
                isEnabled: !space.isSkipped
            ))
        }
        for favorites in plan.favorites {
            var parts: [String] = []
            if favorites.toFavorites > 0 { parts.append(count(favorites.toFavorites, "favorite")) }
            if favorites.overflow > 0 { parts.append("\(favorites.overflow) over the limit of \(BrowserFavorites.limit) pinned") }
            if favorites.alreadyThere > 0 { parts.append("\(favorites.alreadyThere) there already") }
            rows.append(Row(
                item: .favorites(favorites.profileKey),
                section: "Favorites",
                title: "Favorites of \(sourceName(favorites.profileKey, in: plan))",
                detail: parts.joined(separator: " · ") + " → \(target(favorites.profileKey, in: plan))",
                isChecked: favorites.isIncluded && !favorites.links.isEmpty,
                isEnabled: !favorites.links.isEmpty
            ))
        }
        for folder in plan.folders {
            let detail = folder.alreadyThere
                ? "The Space has a folder of that name; skipped"
                : "\(count(folder.pinCount, "pin")) · \(count(folder.folderCount, "folder")) → a pinned folder"
            rows.append(Row(
                item: .folder(folder.id),
                section: "Bookmarks",
                title: folder.name,
                detail: detail,
                isChecked: folder.isIncluded,
                isEnabled: !folder.alreadyThere && !folder.nodes.isEmpty
            ))
        }
        if let archive = plan.archive {
            var detail = "\(count(archive.newCount, "new tab")) of \(archive.items.count)"
            if archive.spacelessCount > 0 { detail += " · \(archive.spacelessCount) without a Space go to Default" }
            rows.append(Row(
                item: .archive,
                section: "Archive",
                title: "Archived tabs",
                detail: detail,
                isChecked: archive.isIncluded && archive.newCount > 0,
                isEnabled: archive.newCount > 0
            ))
        }
        for history in plan.history {
            let destination = history.profileKey.map { target($0, in: plan) } ?? "this window's profile"
            var detail = count(history.visitCount, "visit")
            if let cutoff = plan.historyCutoff {
                detail += " since \(cutoff.formatted(date: .abbreviated, time: .omitted))"
            }
            detail += " → \(destination)"
            if history.olderCount > 0 {
                detail += " · \(history.olderCount.formatted()) older ones left out per Settings ▸ Remove history items"
            }
            rows.append(Row(
                item: .history(history.id),
                section: "History",
                title: history.profileKey.map { "History of \(sourceName($0, in: plan))" } ?? history.title,
                detail: detail,
                isChecked: history.isIncluded,
                isEnabled: history.visitCount > 0
            ))
        }
        if let routing = plan.routing {
            let importable = plan.importableRuleCount
            var detail = count(importable, "rule")
            let notImported = routing.rules.count - importable
            if notImported > 0 { detail += " · \(notImported) for Little Arc, a profile or an unchecked Space not imported" }
            rows.append(Row(
                item: .routing,
                section: "Links from other apps",
                title: "Air Traffic Control rules",
                detail: detail,
                isChecked: routing.isIncluded && importable > 0,
                isEnabled: importable > 0
            ))
        }
        return rows
    }

    /// Checks or unchecks one item.
    static func set(_ item: Item, included: Bool, in plan: inout BrowserImportPlan) {
        switch item {
        case let .space(id):
            if let index = plan.spaces.firstIndex(where: { $0.id == id }), !plan.spaces[index].isSkipped {
                plan.spaces[index].isIncluded = included
            }
        case let .favorites(key):
            if let index = plan.favorites.firstIndex(where: { $0.profileKey == key }) {
                plan.favorites[index].isIncluded = included
            }
        case .archive:
            plan.archive?.isIncluded = included
        case .routing:
            plan.routing?.isIncluded = included
        case let .folder(id):
            if let index = plan.folders.firstIndex(where: { $0.id == id }) {
                plan.folders[index].isIncluded = included
            }
        case let .history(id):
            if let index = plan.history.firstIndex(where: { $0.id == id }) {
                plan.history[index].isIncluded = included
            }
        }
    }

    /// One line over what is checked: "4 Spaces · 161 pins · 13 favorites…".
    static func summary(of plan: BrowserImportPlan) -> String {
        let spaces = plan.spaces.filter { $0.isIncluded && !$0.isSkipped }
        let folders = plan.folders.filter(\.isIncluded)
        var parts: [String] = []
        if !spaces.isEmpty { parts.append(count(spaces.count, "Space")) }
        let pins = spaces.reduce(0) { $0 + $1.pinCount } + folders.reduce(0) { $0 + $1.pinCount }
        if pins > 0 { parts.append(count(pins, "pin")) }
        let favorites = plan.favorites.filter(\.isIncluded).reduce(0) { $0 + $1.links.count }
        if favorites > 0 { parts.append(count(favorites, "favorite")) }
        if let archive = plan.archive, archive.isIncluded, archive.newCount > 0 {
            parts.append(count(archive.newCount, "archived tab"))
        }
        if plan.includedVisitCount > 0 { parts.append(count(plan.includedVisitCount, "visit")) }
        if let routing = plan.routing, routing.isIncluded, plan.importableRuleCount > 0 {
            parts.append(count(plan.importableRuleCount, "rule"))
        }
        return parts.isEmpty ? "Nothing to import" : parts.joined(separator: " · ")
    }

    /// What an import did, one line per kind.
    static func resultLines(_ summary: BrowserImporter.Summary) -> [String] {
        var lines: [String] = []
        if !summary.profilesCreated.isEmpty {
            lines.append("New \(summary.profilesCreated.count == 1 ? "profile" : "profiles"): "
                + summary.profilesCreated.map { "“\($0)”" }.joined(separator: ", "))
        }
        lines.append("\(count(summary.spacesCreated, "Space")) created"
            + (summary.spacesSkipped > 0 ? ", \(summary.spacesSkipped) imported before" : ""))
        lines.append("\(count(summary.pinsAdded, "pin")) in \(count(summary.foldersAdded, "folder"))")
        lines.append("\(count(summary.favoritesAdded, "favorite"))"
            + (summary.favoritesPinned > 0 ? ", \(summary.favoritesPinned) more pinned" : ""))
        lines.append("\(count(summary.archiveAdded, "archived tab"))")
        lines.append("\(count(summary.rulesAdded, "link rule"))")
        for history in summary.history {
            var line = "\(history.title): \(count(history.count.added, "visit")) added"
            if history.count.skipped > 0 { line += ", \(history.count.skipped.formatted()) there already" }
            line += String(format: " in %.1f s", history.seconds)
            if history.count.cancelled { line += " (cancelled)" }
            if let error = history.error { line += " — \(error)" }
            lines.append(line)
        }
        if summary.cancelled { lines.append("Cancelled; what was imported stays, and importing again adds the rest.") }
        return lines
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    private static func sourceName(_ key: String, in plan: BrowserImportPlan) -> String {
        "“\(plan.profile(key: key)?.displayName ?? key)”"
    }

    private static func target(_ key: String, in plan: BrowserImportPlan) -> String {
        guard let profile = plan.profile(key: key) else { return "Default" }
        switch profile.target {
        case .existing: return "profile “\(profile.targetName)”"
        case .new: return "new profile “\(profile.targetName)”"
        }
    }
}
