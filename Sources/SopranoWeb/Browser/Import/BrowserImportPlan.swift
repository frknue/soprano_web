import CryptoKit
import Foundation

// The plan step of File ▸ Import Browser Data…: pure. A reader's output
// plus a snapshot of the app's stores become a `BrowserImportPlan` that
// lists what an import creates and what it skips, with counts; the sheet
// shows it as a checklist and `BrowserImporter` applies it.

/// Where an import reads from.
enum BrowserImportSourceKind: String, CaseIterable, Sendable {
    case arc
    case chrome
    case brave
    case edge
    case vivaldi
    case chromium
    case safari
    case html

    var title: String {
        switch self {
        case .arc: "Arc"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .safari: "Safari Export"
        case .html: "Bookmarks File"
        }
    }

    /// A Chromium browser's user-data folder under `~/Library/Application
    /// Support`; nil for the other sources.
    var chromiumFolder: String? {
        switch self {
        case .chrome: "Google/Chrome"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .arc, .safari, .html: nil
        }
    }

    var isChromium: Bool { chromiumFolder != nil }

    static var chromiumBrowsers: [BrowserImportSourceKind] {
        allCases.filter(\.isChromium)
    }
}

/// What a source held, read off the main thread (`BrowserImportLoader`).
/// History stays in its database; only counts are read up front (`kept`:
/// the visits Settings ▸ Remove history items keeps, what is imported).
enum BrowserImportSourceData: Sendable {
    typealias HistoryCounts = BrowserChromiumHistoryReader.Counts

    /// One Chromium profile: its bookmarks and History.
    struct ChromeProfile: Sendable, Equatable {
        var profile: BrowserImportedProfile
        var bookmarks: [BrowserImportedNode]
        var historyFile: URL?
        var historyCounts: HistoryCounts
    }

    /// Arc's support folder; `historyCounts` by Arc profile key.
    case arc(BrowserArcImport, historyCounts: [String: HistoryCounts])
    /// A Chromium browser (Chrome, Brave, Edge, Vivaldi, Chromium) and its
    /// profiles.
    case chromium(BrowserImportSourceKind, [ChromeProfile])
    /// A Safari export ZIP and its file name.
    case safari(BrowserSafariExport, name: String)
    /// A Netscape bookmarks file and its file name.
    case html([BrowserImportedNode], name: String)
}

// MARK: - Plan

struct BrowserImportPlan: Sendable {
    /// Where a source profile's History and favorites go: its home Space.
    struct Profile: Sendable, Equatable {
        enum Target: Sendable, Equatable {
            /// The Space whose profile has this id (the Default Space, or
            /// the one an earlier import made the home).
            case existing(UUID)
            /// The first of the source profile's Spaces this import makes,
            /// else a new Space named `name`.
            case new(name: String)
        }

        /// The source's key (`Default`, `Profile 3`).
        var key: String
        /// The source's name for it.
        var displayName: String
        var target: Target
        /// The home Space's name (a new one's: `name`).
        var targetName: String
        /// An existing home Space nothing was put in yet (no pins, never
        /// imported): the profile's first new Space takes it over instead
        /// of adding a Space (the Default Space of a fresh install).
        var adoptableSpaceID: UUID?
    }

    /// An Arc Space.
    struct Space: Sendable, Identifiable {
        /// Arc's Space id, kept as the new Space's `importedFrom`.
        var id: String
        var name: String
        var icon: BrowserSpaceIcon
        var color: BrowserProfileColor
        var profileKey: String
        var pinned: [BrowserImportedNode]
        var today: [BrowserImportedLink]
        /// Arc's split views among `today`, as indices of `today`.
        var todaySplits: [[Int]] = []
        var pinCount: Int
        var folderCount: Int
        /// The Space an earlier import made from it: skipped.
        var existingSpaceID: UUID?
        var isIncluded: Bool

        var isSkipped: Bool { existingSpaceID != nil }
    }

    /// A source profile's favorites, for its home Space. `links` are the
    /// ones the home doesn't have yet; the first `capacity` become
    /// favorites, the rest are pinned at the end of the home Space.
    struct Favorites: Sendable {
        var profileKey: String
        var links: [BrowserImportedLink]
        /// Links the profile has as favorites already.
        var alreadyThere: Int
        /// Free favorite places (at most `BrowserFavorites.limit`).
        var capacity: Int
        var isIncluded: Bool

        var toFavorites: Int { min(links.count, capacity) }
        var overflow: Int { links.count - toFavorites }
    }

    struct Archive: Sendable {
        /// Oldest first.
        var items: [BrowserImportedArchiveItem]
        /// Items the Archive doesn't hold yet.
        var newCount: Int
        /// Items without a Space (Little Arc, unknown): into the Default
        /// Space.
        var spacelessCount: Int
        var isIncluded: Bool
    }

    struct Routing: Sendable {
        var rules: [BrowserImportedRoutingRule]
        /// Rules for a Space (the most recent or a specific one).
        var importable: Int
        /// Rules for Little Arc or a profile: not imported.
        var unsupported: Int
        var isIncluded: Bool
        /// Arc's `defaultDestination` as "Open links from other apps in":
        /// Little Arc, or (a Space) the most recent window; nil without one.
        var otherLinks: BrowserOutsideLinkDestination? = nil
    }

    /// Bookmarks (Chrome, Safari, a bookmarks file) as one pinned folder.
    struct Folder: Sendable, Identifiable {
        var id: String
        var name: String
        var nodes: [BrowserImportedNode]
        var pinCount: Int
        var folderCount: Int
        /// The target Space has a top-level folder of that name: skipped.
        var alreadyThere: Bool
        var isIncluded: Bool
    }

    struct History: Sendable, Identifiable {
        enum Source: Sendable {
            /// A Chromium `History` database (Arc, Chrome), its visits at or
            /// after `since` (History's retention cutoff).
            case chromium(URL, since: Date?)
            /// Visits read already (Safari's export: one per page, at its
            /// last visit).
            case visits([BrowserImportedVisit])
        }

        var id: String
        var title: String
        /// The Arc profile it belongs to (its home Space's); nil: the
        /// target Space's.
        var profileKey: String?
        var source: Source
        /// The visits this imports.
        var visitCount: Int
        var isIncluded: Bool
        /// Every visit in the source database (subframes, hidden and
        /// `chrome:` pages included).
        var sourceVisitCount = 0
        /// Importable visits older than Settings ▸ Remove history items
        /// keeps: left out.
        var olderCount = 0
    }

    var source: BrowserImportSourceKind
    var sourceName: String
    var profiles: [Profile] = []
    var spaces: [Space] = []
    var favorites: [Favorites] = []
    var archive: Archive?
    var routing: Routing?
    var folders: [Folder] = []
    var history: [History] = []
    /// Where bookmark folders go and whose History non-Arc History joins:
    /// the Space chosen in the sheet (the importing window's at first;
    /// `BrowserImportPlanner.retarget`).
    var targetSpaceID: UUID?
    /// Arc item id → its cached favicon file.
    var favicons: [String: URL] = [:]
    /// History older than this (Settings ▸ Remove history items) is left
    /// out; nil imports all of it.
    var historyCutoff: Date?
    /// The Default Space's name, where Spaceless archived tabs go.
    var defaultSpaceName = BrowserProfile.defaultName

    func profile(key: String) -> Profile? {
        profiles.first { $0.key == key }
    }

    /// The first checked new Space of source profile `key`: the one that
    /// becomes its home (or takes the home over).
    func firstNewSpace(ofProfile key: String) -> Space? {
        spaces.first { $0.profileKey == key && $0.isIncluded && !$0.isSkipped }
    }

    /// The Space a checked new Space takes over (its profile's untouched
    /// home), if any.
    func adoptedSpaceID(by space: Space) -> UUID? {
        guard let profile = profile(key: space.profileKey), let adoptable = profile.adoptableSpaceID,
              firstNewSpace(ofProfile: space.profileKey)?.id == space.id
        else { return nil }
        return adoptable
    }

    /// Where source profile `key`'s History and favorites go, as the sheet
    /// names it.
    func homeName(ofProfile key: String) -> String {
        guard let profile = profile(key: key) else { return "“\(defaultSpaceName)”" }
        switch profile.target {
        case .existing:
            return "“\(profile.targetName)”"
        case .new:
            if let first = firstNewSpace(ofProfile: key) {
                let name = first.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return "“\(name.isEmpty ? BrowserSpace.defaultName : name)”"
            }
            return "new Space “\(profile.targetName)”"
        }
    }

    /// Visits of the included History items.
    var includedVisitCount: Int {
        history.filter(\.isIncluded).reduce(0) { $0 + $1.visitCount }
    }

    /// Rules an import of the plan as checked brings in: those for the most
    /// recent Space, and those whose Space is checked or imported before.
    var importableRuleCount: Int {
        (routing?.rules ?? []).filter { rule in
            guard case let .space(sourceID) = rule.destination else { return false }
            guard let sourceID else { return true }
            return spaces.contains { $0.id == sourceID && ($0.isIncluded || $0.isSkipped) }
        }.count
    }
}

// MARK: - Planner

enum BrowserImportPlanner {
    /// What the plan compares the source with.
    struct Context: Sendable {
        var profiles: [BrowserProfile]
        var spaces: BrowserSpaceList
        var archiveIDs: Set<UUID>
        var routingRules: [BrowserLinkRoutingRule]
        var targetSpaceID: UUID?
        /// Settings ▸ Remove history items: older visits aren't imported
        /// (the retention pass would remove them again).
        var historyCutoff: Date?
    }

    /// The profile `importedFrom` an Arc profile is recorded as.
    static func arcProfileSource(_ key: String) -> String { "arc:\(key)" }

    static func plan(for data: BrowserImportSourceData, context: Context) -> BrowserImportPlan {
        var plan: BrowserImportPlan = switch data {
        case let .arc(arc, counts): self.arc(arc, historyCounts: counts, context: context)
        case let .chromium(browser, profiles): chromium(browser, profiles, context: context)
        case let .safari(export, name): safari(export, name: name, context: context)
        case let .html(nodes, name): bookmarksFile(nodes, name: name, context: context)
        }
        plan.historyCutoff = context.historyCutoff
        return plan
    }

    // MARK: Arc

    /// Arc → app: every Arc Space becomes a Space of its own, with its own
    /// cookies, History and Archive. An Arc profile's History and favorites
    /// go to its home Space: Arc's `Default` → the Default Space; `Profile
    /// N` → the Space an earlier import made its home (the profile marked
    /// `arc:Profile N`), else the first of its Spaces this import makes,
    /// else a new Space named after its first Space (its Arc name when it
    /// has none). A home nothing was put in yet (the Default Space of a
    /// fresh install) is taken over by the profile's first new Space.
    /// Spaces an earlier import made are skipped. A profile with History
    /// but no Space or favorites is offered unchecked.
    static func arc(
        _ data: BrowserArcImport,
        historyCounts: [String: BrowserImportSourceData.HistoryCounts],
        context: Context
    ) -> BrowserImportPlan {
        var plan = BrowserImportPlan(source: .arc, sourceName: BrowserImportSourceKind.arc.title)
        plan.targetSpaceID = context.targetSpaceID
        plan.favicons = data.favicons
        plan.defaultSpaceName = context.spaces.defaultSpace?.displayName ?? BrowserProfile.defaultName
        let profileList = BrowserProfileList(context.profiles)

        for profile in data.profiles {
            let spaces = data.spaces.filter { $0.profileKey == profile.key }
            let target: BrowserImportPlan.Profile.Target
            let targetName: String
            let home: BrowserSpace?
            if profile.isDefault {
                home = context.spaces.defaultSpace
                target = .existing(BrowserProfile.defaultID)
                targetName = home?.displayName ?? BrowserProfile.defaultName
            } else if let earlier = profileList.profile(importedFrom: arcProfileSource(profile.key)),
                      let space = context.spaces.space(ofProfile: earlier.id)
            {
                home = space
                target = .existing(earlier.id)
                targetName = space.displayName
            } else {
                let spaceName = spaces.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = spaceName.isEmpty ? profile.displayName : spaceName
                target = .new(name: name)
                targetName = name
                home = nil
            }
            plan.profiles.append(BrowserImportPlan.Profile(
                key: profile.key,
                displayName: profile.displayName,
                target: target,
                targetName: targetName,
                adoptableSpaceID: home.flatMap { $0.importedFrom == nil && $0.pinned.isEmpty ? $0.id : nil }
            ))
        }

        for space in data.spaces {
            let counts = nodeCounts(space.pinned)
            let existing = context.spaces.space(importedFrom: space.sourceID)?.id
            plan.spaces.append(BrowserImportPlan.Space(
                id: space.sourceID,
                name: space.name,
                icon: space.emoji.map(BrowserSpaceIcon.emoji) ?? .none,
                color: BrowserImportColorMatch.profileColor(for: space.color) ?? .blue,
                profileKey: space.profileKey,
                pinned: space.pinned,
                today: space.today,
                todaySplits: space.todaySplits,
                pinCount: counts.pins,
                folderCount: counts.folders,
                existingSpaceID: existing,
                isIncluded: existing == nil
            ))
        }

        for favorites in data.favorites {
            var present: Set<String> = []
            if case let .existing(id) = plan.profile(key: favorites.profileKey)?.target {
                present = Set(context.spaces.favorites(ofProfile: id).items.map(\.url))
            }
            let held = present.count
            var links: [BrowserImportedLink] = []
            var alreadyThere = 0
            for link in favorites.links {
                if present.contains(link.url) {
                    alreadyThere += 1
                    continue
                }
                present.insert(link.url)
                links.append(link)
            }
            plan.favorites.append(BrowserImportPlan.Favorites(
                profileKey: favorites.profileKey,
                links: links,
                alreadyThere: alreadyThere,
                capacity: max(0, BrowserFavorites.limit - held),
                isIncluded: true
            ))
        }

        if !data.archive.isEmpty {
            plan.archive = BrowserImportPlan.Archive(
                items: data.archive,
                newCount: data.archive.filter { !context.archiveIDs.contains(archiveEntryID(for: $0)) }.count,
                spacelessCount: data.archive.filter { $0.spaceSourceID == nil }.count,
                isIncluded: true
            )
        }

        let otherLinks = data.defaultLinkDestination.map { destination -> BrowserOutsideLinkDestination in
            if case .littleArc = destination { return .littleArc }
            return .mostRecentWindow
        }
        if !data.routingRules.isEmpty || otherLinks != nil {
            let importable = data.routingRules.filter {
                if case .space = $0.destination { return true }
                return false
            }
            plan.routing = BrowserImportPlan.Routing(
                rules: data.routingRules,
                importable: importable.count,
                unsupported: data.routingRules.count - importable.count,
                isIncluded: !importable.isEmpty || otherLinks != nil,
                otherLinks: otherLinks
            )
        }

        let used = Set(data.spaces.map(\.profileKey) + data.favorites.map(\.profileKey))
        for profile in data.profiles {
            guard let file = data.historyFiles[profile.key] else { continue }
            let counts = historyCounts[profile.key]
            plan.history.append(BrowserImportPlan.History(
                id: "arc:\(profile.key)",
                title: profile.displayName,
                profileKey: profile.key,
                source: .chromium(file, since: context.historyCutoff),
                visitCount: counts?.kept ?? 0,
                isIncluded: used.contains(profile.key),
                sourceVisitCount: counts?.visits ?? 0,
                olderCount: counts.map { $0.importable - $0.kept } ?? 0
            ))
        }
        return plan
    }

    /// The Archive id of an imported entry: Arc's item UUID, so a
    /// re-import finds it (a non-UUID id gets a UUID derived from it).
    static func archiveEntryID(for item: BrowserImportedArchiveItem) -> UUID {
        let source = item.link.sourceID ?? "\(item.link.url)|\(item.archivedAt.timeIntervalSinceReferenceDate)"
        if let id = UUID(uuidString: source) { return id }
        let digest = Array(Insecure.MD5.hash(data: Data(source.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    // MARK: Chromium browsers, Safari, bookmarks files

    /// Points a non-Arc plan at Space `spaceID`
    /// (the sheet's Space menu): its folders go there (one the Space has
    /// a top-level folder of that name for is skipped) and its History
    /// joins that Space's.
    static func retarget(_ plan: inout BrowserImportPlan, to spaceID: UUID, spaces: BrowserSpaceList) {
        guard plan.source != .arc, spaces.space(id: spaceID) != nil else { return }
        plan.targetSpaceID = spaceID
        let root = spaces.space(id: spaceID)?.pinned.root
        for index in plan.folders.indices {
            let wasThere = plan.folders[index].alreadyThere
            let there = root?.children.contains { $0.folder?.name == plan.folders[index].name } ?? false
            plan.folders[index].alreadyThere = there
            if there {
                plan.folders[index].isIncluded = false
            } else if wasThere {
                plan.folders[index].isIncluded = !plan.folders[index].nodes.isEmpty
            }
        }
    }

    /// Each profile's bookmarks become one pinned folder ("Chrome
    /// Bookmarks", with the profile's name when several have bookmarks)
    /// in the target Space; each profile's History goes to the target
    /// Space. Names and ids carry the browser's (`Brave Bookmarks`,
    /// `brave:Default`), so a re-import skips its own folder.
    static func chromium(
        _ browser: BrowserImportSourceKind,
        _ profiles: [BrowserImportSourceData.ChromeProfile],
        context: Context
    ) -> BrowserImportPlan {
        let name = browser.title
        var plan = BrowserImportPlan(source: browser, sourceName: name)
        plan.targetSpaceID = context.targetSpaceID
        let withBookmarks = profiles.filter { !$0.bookmarks.isEmpty }
        for profile in withBookmarks {
            let folderName = withBookmarks.count == 1
                ? "\(name) Bookmarks"
                : "\(name) Bookmarks (\(profile.profile.displayName))"
            plan.folders.append(folder(id: "\(browser.rawValue):\(profile.profile.key)", name: folderName, nodes: profile.bookmarks, context: context))
        }
        for profile in profiles {
            guard let file = profile.historyFile else { continue }
            plan.history.append(BrowserImportPlan.History(
                id: "\(browser.rawValue):\(profile.profile.key)",
                title: profiles.count == 1 ? "\(name) History" : "\(name) History (\(profile.profile.displayName))",
                profileKey: nil,
                source: .chromium(file, since: context.historyCutoff),
                visitCount: profile.historyCounts.kept,
                isIncluded: true,
                sourceVisitCount: profile.historyCounts.visits,
                olderCount: profile.historyCounts.importable - profile.historyCounts.kept
            ))
        }
        return plan
    }

    /// Safari's export: `Bookmarks.html` as one pinned folder, each
    /// History file into the target Space, one visit per page at its last
    /// visit time.
    static func safari(_ export: BrowserSafariExport, name: String, context: Context) -> BrowserImportPlan {
        var plan = BrowserImportPlan(source: .safari, sourceName: name)
        plan.targetSpaceID = context.targetSpaceID
        if !export.bookmarks.isEmpty {
            plan.folders.append(folder(id: "safari:bookmarks", name: "Safari Bookmarks", nodes: export.bookmarks, context: context))
        }
        for (index, history) in export.histories.enumerated() {
            // One visit per page at its last visit, not `visits_count` of them.
            let all = history.visits.map { visit in
                BrowserImportedVisit(url: visit.url, title: visit.title, visitedAt: visit.visitedAt, typed: visit.typed)
            }
            let kept = context.historyCutoff.map { cutoff in all.filter { $0.visitedAt >= cutoff } } ?? all
            plan.history.append(BrowserImportPlan.History(
                id: "safari:\(index)",
                title: history.profileName.map { "Safari History (\($0))" } ?? "Safari History",
                profileKey: nil,
                source: .visits(kept),
                visitCount: kept.count,
                isIncluded: true,
                sourceVisitCount: history.visits.count,
                olderCount: all.count - kept.count
            ))
        }
        return plan
    }

    /// A Netscape bookmarks file as one pinned folder named after it.
    static func bookmarksFile(_ nodes: [BrowserImportedNode], name: String, context: Context) -> BrowserImportPlan {
        var plan = BrowserImportPlan(source: .html, sourceName: name)
        plan.targetSpaceID = context.targetSpaceID
        let stem = (name as NSString).deletingPathExtension
        plan.folders.append(folder(id: "html", name: stem.isEmpty ? "Imported Bookmarks" : stem, nodes: nodes, context: context))
        return plan
    }

    private static func folder(id: String, name: String, nodes: [BrowserImportedNode], context: Context) -> BrowserImportPlan.Folder {
        let counts = nodeCounts(nodes)
        let root = context.targetSpaceID.flatMap { context.spaces.space(id: $0) }?.pinned.root
        let alreadyThere = root?.children.contains { $0.folder?.name == name } ?? false
        return BrowserImportPlan.Folder(
            id: id,
            name: name,
            nodes: nodes,
            pinCount: counts.pins,
            folderCount: counts.folders,
            alreadyThere: alreadyThere,
            isIncluded: !alreadyThere && !nodes.isEmpty
        )
    }

    // MARK: Trees

    static func nodeCounts(_ nodes: [BrowserImportedNode]) -> (pins: Int, folders: Int) {
        nodes.reduce((0, 0)) { counts, node in
            switch node {
            case .link: return (counts.0 + 1, counts.1)
            case let .folder(folder):
                let inner = nodeCounts(folder.children)
                return (counts.0 + inner.pins, counts.1 + 1 + inner.folders)
            }
        }
    }

    /// Imported nodes as pins and folders (new ids; a missing date is now).
    static func pinNodes(_ nodes: [BrowserImportedNode], now: Date = Date()) -> [BrowserPinNode] {
        nodes.map { node in
            switch node {
            case let .link(link):
                .pin(BrowserPin(url: link.url, title: link.title, addedAt: link.addedAt ?? now))
            case let .folder(folder):
                .folder(BrowserPinFolder(
                    name: folder.name,
                    addedAt: folder.addedAt ?? now,
                    children: pinNodes(folder.children, now: now)
                ))
            }
        }
    }

    /// Pins and folders as the neutral model (what the bookmarks export
    /// writes).
    static func importedNodes(_ nodes: [BrowserPinNode]) -> [BrowserImportedNode] {
        nodes.map { node in
            switch node {
            case let .pin(pin):
                .link(BrowserImportedLink(url: pin.url, title: pin.displayTitle, addedAt: pin.addedAt))
            case let .folder(folder):
                .folder(BrowserImportedFolder(
                    name: folder.name,
                    addedAt: folder.addedAt,
                    children: importedNodes(folder.children)
                ))
            }
        }
    }
}

// MARK: - Colors

/// A source color's nearest Folio color (`BrowserProfileColor`), by
/// perceptual hue: the extended-sRGB components are converted to OKLab
/// (through linear sRGB, which keeps a component outside 0…1 as the color
/// it is: Arc's vivid green with `red` -0.385 stays green instead of being
/// clamped toward teal), then matched against the OKLab hues of Folio
/// Paper's tokens. A color with little chroma is gray.
enum BrowserImportColorMatch {
    /// OKLab hues (degrees) of Folio Paper's `danger`, `yellow`,
    /// `success`, `cyan` and `blue`.
    static let hues: [(color: BrowserProfileColor, hue: Double)] = [
        (.red, 19.8),
        (.yellow, 81.6),
        (.green, 135.6),
        (.cyan, 188.5),
        (.blue, 247.8),
    ]
    /// Below this OKLab chroma a color reads as gray.
    static let grayChroma = 0.05

    static func profileColor(for color: BrowserImportedColor?) -> BrowserProfileColor? {
        guard let color else { return nil }
        let lab = oklab(color)
        guard lab.chroma >= grayChroma, lab.lightness >= 0.2 else { return .gray }
        return hues.min { distance($0.hue, lab.hue) < distance($1.hue, lab.hue) }?.color
    }

    /// Extended sRGB → OKLab lightness, chroma and hue (degrees).
    static func oklab(_ color: BrowserImportedColor) -> (lightness: Double, chroma: Double, hue: Double) {
        func linear(_ value: Double) -> Double {
            let magnitude = abs(value)
            let result = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
            return value < 0 ? -result : result
        }
        let (r, g, b) = (linear(color.red), linear(color.green), linear(color.blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bValue = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bValue, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (lightness, (a * a + bValue * bValue).squareRoot(), hue)
    }

    private static func distance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
