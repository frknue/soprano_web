import Foundation

/// The apply step of an import: writes a `BrowserImportPlan`'s included
/// items into the app's stores on the main actor (profiles, Spaces and
/// pins, favorites, the Archive, favicons, link routing), then imports
/// History off the main thread, one profile after another, in batches
/// that can be cancelled. Running a plan twice adds nothing the first run
/// added: Spaces carry `importedFrom`, favorites and overflow pins are
/// matched by address, Archive entries keep Arc's ids, rules are compared
/// and History skips visits it holds (same address and time).
@MainActor
final class BrowserImporter {
    struct Stores {
        var profiles: BrowserProfileStore
        var spaces: BrowserSpaceStore
        var archive: BrowserArchiveStore
        var favicons: BrowserFaviconStore
        var linkRouting: BrowserLinkRoutingStore
        var history: @MainActor (BrowserProfile) -> BrowserHistoryStore
    }

    /// One History item's outcome.
    struct HistoryResult: Sendable, Equatable {
        var id: String
        var title: String
        var profileName: String
        var count = BrowserHistoryImportCount()
        var seconds: Double = 0
        var error: String?
    }

    struct Summary: Sendable {
        var profilesCreated: [String] = []
        var spacesCreated = 0
        var spacesSkipped = 0
        var pinsAdded = 0
        var foldersAdded = 0
        var favoritesAdded = 0
        /// Favorites past the limit, pinned in the profile's first Space.
        var favoritesPinned = 0
        var archiveAdded = 0
        var faviconsAdded = 0
        var rulesAdded = 0
        /// The Today tabs to open, by the Space they belong to.
        var todayTabs: [(spaceID: UUID, links: [BrowserImportedLink])] = []
        /// The first Space this import made (the window switches to it).
        var firstSpaceID: UUID?
        var history: [HistoryResult] = []
        var cancelled = false

        var visitsAdded: Int { history.reduce(0) { $0 + $1.count.added } }
        var visitsSkipped: Int { history.reduce(0) { $0 + $1.count.skipped } }
    }

    /// Progress: History visits handled of `total`.
    struct Progress: Sendable, Equatable {
        var handled: Int
        var total: Int
        var item: String

        var fraction: Double { total > 0 ? min(1, Double(handled) / Double(total)) : 1 }
    }

    /// Visits per History transaction.
    nonisolated static let historyBatchSize = 2_000

    let stores: Stores
    private var profileMap: [String: UUID] = [:]
    /// A profile this import made → the Space it was given, which the
    /// profile's first imported Space takes over.
    private var adoptable: [UUID: UUID] = [:]

    init(stores: Stores) {
        self.stores = stores
    }

    /// Applies `plan`: the store step at once, then History in the
    /// background; `completion` gets everything once History is done or
    /// cancelled. Returns the store step's result (for the Today tabs).
    @discardableResult
    func run(
        _ plan: BrowserImportPlan,
        cancellation: BrowserImportCancellation,
        progress: @escaping @MainActor @Sendable (Progress) -> Void,
        completion: @escaping @MainActor @Sendable (Summary) -> Void
    ) -> Summary {
        let result = applyStores(plan)
        importHistory(plan, into: result, cancellation: cancellation, progress: progress, completion: completion)
        return result
    }

    // MARK: Stores

    /// Everything but History, synchronously.
    func applyStores(_ plan: BrowserImportPlan) -> Summary {
        var result = Summary()
        var spaceMap: [String: UUID] = [:]

        for space in plan.spaces {
            if let existing = space.existingSpaceID, stores.spaces.space(id: existing) != nil {
                spaceMap[space.id] = existing
                result.spacesSkipped += 1
                continue
            }
            guard space.isIncluded,
                  let profile = resolveProfile(space.profileKey, in: plan, color: space.color, result: &result)
            else { continue }
            let tree = BrowserPinTree(children: BrowserImportPlanner.pinNodes(space.pinned))
            var spaceID: UUID?
            if let given = adoptable[profile.id],
               stores.spaces.adoptSpace(given, name: space.name, icon: space.icon, color: space.color, pinned: tree, importedFrom: space.id)
            {
                adoptable[profile.id] = nil
                spaceID = given
            } else {
                spaceID = stores.spaces.createSpace(
                    name: space.name,
                    icon: space.icon,
                    color: space.color,
                    profileID: profile.id,
                    pinned: tree,
                    importedFrom: space.id
                )?.id
            }
            guard let spaceID else { continue }
            spaceMap[space.id] = spaceID
            result.spacesCreated += 1
            result.pinsAdded += space.pinCount
            result.foldersAdded += space.folderCount
            result.firstSpaceID = result.firstSpaceID ?? spaceID
            if !space.today.isEmpty {
                result.todayTabs.append((spaceID, space.today))
            }
        }

        for favorites in plan.favorites where favorites.isIncluded && !favorites.links.isEmpty {
            guard let profile = resolveProfile(favorites.profileKey, in: plan, color: nil, result: &result) else { continue }
            var present = Set(stores.spaces.favorites(ofProfile: profile.id).map(\.url))
            var overflow: [BrowserImportedLink] = []
            for link in favorites.links where present.insert(link.url).inserted {
                let pin = BrowserPin(url: link.url, title: link.title, addedAt: link.addedAt ?? Date())
                if stores.spaces.insertFavorite(pin, ofProfile: profile.id) {
                    result.favoritesAdded += 1
                } else {
                    overflow.append(link)
                }
            }
            guard !overflow.isEmpty else { continue }
            let imported = plan.spaces.lazy
                .filter { $0.profileKey == favorites.profileKey }
                .compactMap { spaceMap[$0.id] }
                .first { self.stores.spaces.space(id: $0)?.profileID == profile.id }
            guard let target = imported ?? stores.spaces.firstSpace(ofProfile: profile.id)?.id else { continue }
            var pinned = Set(stores.spaces.pins(inSpace: target).map(\.url))
            for link in overflow where pinned.insert(link.url).inserted {
                let node = BrowserPinNode.pin(BrowserPin(url: link.url, title: link.title, addedAt: link.addedAt ?? Date()))
                if stores.spaces.insert(node, inSpace: target) {
                    result.favoritesPinned += 1
                }
            }
        }

        if let archive = plan.archive, archive.isIncluded {
            let defaultSpace = stores.spaces.firstSpace(ofProfile: BrowserProfile.defaultID)?.id
            let entries = archive.items.compactMap { item -> BrowserArchiveEntry? in
                guard BrowserArchiveEntry.isArchivable(URL(string: item.link.url)) else { return nil }
                var spaceID = item.spaceSourceID.flatMap { spaceMap[$0] }
                var profileID = BrowserProfile.defaultID
                if let id = spaceID, let space = stores.spaces.space(id: id) {
                    profileID = space.profileID
                } else if let key = item.spaceSourceID.flatMap({ id in plan.spaces.first { $0.id == id }?.profileKey }),
                          let mapped = existingProfile(key, in: plan) {
                    // The Space wasn't imported; its profile's Archive.
                    profileID = mapped
                    spaceID = nil
                } else {
                    spaceID = defaultSpace
                }
                return BrowserArchiveEntry(
                    id: BrowserImportPlanner.archiveEntryID(for: item),
                    url: item.link.url,
                    title: item.link.title,
                    spaceID: spaceID,
                    profileID: profileID,
                    archivedAt: item.archivedAt,
                    reason: .imported,
                    faviconKey: BrowserFaviconSelection.key(for: URL(string: item.link.url))
                )
            }
            result.archiveAdded = stores.archive.insert(entries, reason: .imported)
        }

        if let routing = plan.routing, routing.isIncluded {
            let rules = routing.rules.compactMap { rule -> BrowserLinkRoutingRule? in
                guard case let .space(sourceID) = rule.destination else { return nil }
                let destination: BrowserLinkRoutingRule.Destination
                if let sourceID {
                    guard let spaceID = spaceMap[sourceID] else { return nil }
                    destination = .space(spaceID)
                } else {
                    destination = .mostRecentSpace
                }
                let match: BrowserLinkRoutingRule.Match = switch rule.match {
                case .contains: .contains
                case .equals: .equals
                case .prefix: .prefix
                }
                return BrowserLinkRoutingRule(match: match, value: rule.value, destination: destination, importedFrom: plan.source.rawValue)
            }
            result.rulesAdded = stores.linkRouting.add(rules)
        }

        if !plan.folders.isEmpty {
            let target = plan.targetSpaceID.flatMap { stores.spaces.space(id: $0) }
                ?? stores.spaces.firstSpace(ofProfile: BrowserProfile.defaultID)
            for folder in plan.folders where folder.isIncluded {
                guard let target else { break }
                let root = stores.spaces.pinTree(inSpace: target.id).root
                guard !root.children.contains(where: { $0.folder?.name == folder.name }) else { continue }
                let node = BrowserPinNode.folder(BrowserPinFolder(
                    name: folder.name,
                    children: BrowserImportPlanner.pinNodes(folder.nodes)
                ))
                guard stores.spaces.insert(node, inSpace: target.id) else { continue }
                result.pinsAdded += folder.pinCount
                result.foldersAdded += folder.folderCount + 1
            }
        }

        result.faviconsAdded = importFavicons(plan, spaceMap: spaceMap)
        return result
    }

    /// Arc's cached icons of the links this import brought in.
    private func importFavicons(_ plan: BrowserImportPlan, spaceMap: [String: UUID]) -> Int {
        guard !plan.favicons.isEmpty else { return 0 }
        var links = plan.spaces.filter { $0.isIncluded && spaceMap[$0.id] != nil }
            .flatMap { $0.pinned.flatMap(\.links) + $0.today }
        links += plan.favorites.filter(\.isIncluded).flatMap(\.links)
        if plan.archive?.isIncluded == true {
            links += plan.archive?.items.map(\.link) ?? []
        }
        let icons = links.compactMap { link -> (address: String, file: URL)? in
            guard let id = link.sourceID, let file = plan.favicons[id] else { return nil }
            return (link.url, file)
        }
        return stores.favicons.importIcons(icons)
    }

    /// The app profile for a source profile, made (with its Space, which
    /// the first imported Space takes over) the first time it is needed.
    private func resolveProfile(
        _ key: String,
        in plan: BrowserImportPlan,
        color: BrowserProfileColor?,
        result: inout Summary
    ) -> BrowserProfile? {
        if let id = profileMap[key] {
            return stores.profiles.profile(id: id)
        }
        guard let mapping = plan.profile(key: key) else {
            return stores.profiles.profile(id: BrowserProfile.defaultID)
        }
        let profile: BrowserProfile
        switch mapping.target {
        case let .existing(id):
            guard let existing = stores.profiles.profile(id: id) else { return nil }
            profile = existing
        case let .new(name):
            let source = BrowserImportPlanner.arcProfileSource(key)
            if let earlier = stores.profiles.profile(importedFrom: source) {
                profile = earlier
            } else {
                profile = stores.profiles.add(name: name, color: color, importedFrom: source)
                result.profilesCreated.append(profile.name)
                // The manager reconciles on every profile change; without
                // it (tests) the store gives the profile its Space here.
                adoptable[profile.id] = stores.spaces.ensureSpace(forProfile: profile).id
            }
        }
        profileMap[key] = profile.id
        return profile
    }

    /// The app profile a source profile maps to without making one.
    private func existingProfile(_ key: String, in plan: BrowserImportPlan) -> UUID? {
        if let id = profileMap[key] { return id }
        guard case let .existing(id) = plan.profile(key: key)?.target else { return nil }
        return stores.profiles.profile(id: id)?.id
    }

    // MARK: History

    private func importHistory(
        _ plan: BrowserImportPlan,
        into storesResult: Summary,
        cancellation: BrowserImportCancellation,
        progress: @escaping @MainActor @Sendable (Progress) -> Void,
        completion: @escaping @MainActor @Sendable (Summary) -> Void
    ) {
        var result = storesResult
        let targetProfileID = plan.targetSpaceID.flatMap { stores.spaces.space(id: $0)?.profileID }
            ?? BrowserProfile.defaultID
        var jobs: [HistoryRun.Job] = []
        for item in plan.history where item.isIncluded {
            let profile = item.profileKey.flatMap { resolveProfile($0, in: plan, color: nil, result: &result) }
                ?? stores.profiles.profile(id: targetProfileID)
                ?? .defaultProfile
            jobs.append(HistoryRun.Job(item: item, profile: profile, store: stores.history(profile)))
        }
        HistoryRun(
            jobs: jobs,
            result: result,
            cancellation: cancellation,
            progress: progress,
            completion: completion
        ).next()
    }

    /// History items imported one after another; keeps itself alive
    /// through its callbacks until the last one finishes.
    @MainActor
    private final class HistoryRun {
        struct Job: Sendable {
            var item: BrowserImportPlan.History
            var profile: BrowserProfile
            var store: BrowserHistoryStore
        }

        private let jobs: [Job]
        private var result: Summary
        private let cancellation: BrowserImportCancellation
        private let progress: @MainActor @Sendable (Progress) -> Void
        private let completion: @MainActor @Sendable (Summary) -> Void
        private let total: Int
        private var index = 0
        private var done = 0

        init(
            jobs: [Job],
            result: Summary,
            cancellation: BrowserImportCancellation,
            progress: @escaping @MainActor @Sendable (Progress) -> Void,
            completion: @escaping @MainActor @Sendable (Summary) -> Void
        ) {
            self.jobs = jobs
            self.result = result
            self.cancellation = cancellation
            self.progress = progress
            self.completion = completion
            total = jobs.reduce(0) { $0 + $1.item.visitCount }
        }

        func next() {
            guard index < jobs.count, !cancellation.isCancelled else {
                result.cancelled = cancellation.isCancelled
                completion(result)
                return
            }
            let job = jobs[index]
            let started = Date()
            let base = done
            let total = total
            let progress = progress
            progress(Progress(handled: base, total: total, item: job.item.title))
            job.store.importInBackground(
                batchesFrom: BrowserImporter.batches(job.item.source),
                cancellation: cancellation,
                progress: { handled in
                    progress(Progress(handled: base + handled, total: total, item: job.item.title))
                },
                completion: { outcome in
                    self.finish(job, outcome: outcome, seconds: Date().timeIntervalSince(started))
                }
            )
        }

        private func finish(_ job: Job, outcome: Swift.Result<BrowserHistoryImportCount, Error>, seconds: Double) {
            var entry = HistoryResult(id: job.item.id, title: job.item.title, profileName: job.profile.name)
            entry.seconds = seconds
            switch outcome {
            case let .success(count): entry.count = count
            case let .failure(error): entry.error = "\(error)"
            }
            result.history.append(entry)
            done += job.item.visitCount
            progress(Progress(handled: done, total: total, item: job.item.title))
            index += 1
            next()
        }
    }

    /// A History item's visits in batches, read where the batches are
    /// consumed (off the main thread).
    nonisolated static func batches(
        _ source: BrowserImportPlan.History.Source
    ) -> @Sendable (_ body: ([BrowserHistoryImport]) throws -> Void) throws -> Void {
        let convert: @Sendable (BrowserImportedVisit) -> BrowserHistoryImport = { visit in
            BrowserHistoryImport(url: visit.url, title: visit.title, visitedAt: visit.visitedAt, kind: visit.typed ? .typed : .link)
        }
        switch source {
        case let .chromium(file, since):
            return { body in
                try BrowserChromiumHistoryReader(fileURL: file).read(since: since, batchSize: historyBatchSize) { batch in
                    try body(batch.map(convert))
                }
            }
        case let .visits(visits):
            return { body in
                for start in stride(from: 0, to: visits.count, by: historyBatchSize) {
                    try body(visits[start..<min(visits.count, start + historyBatchSize)].map(convert))
                }
            }
        }
    }
}
