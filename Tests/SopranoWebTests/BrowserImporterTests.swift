@testable import SopranoWeb
import AppKit
import Testing

/// The apply step against real stores in a temporary folder: profiles and
/// their one Space, favorites past the limit, the Archive, rules, History,
/// and a second run that adds nothing.
@MainActor
struct BrowserImporterTests {
    private let spaceA = "0A000000-0000-4000-8000-000000000001"
    private let spaceB = "0A000000-0000-4000-8000-000000000002"
    private let spaceC = "0A000000-0000-4000-8000-000000000003"
    private let archivedB = "A1000000-0000-4000-8000-000000000001"
    private let archivedLittle = "A1000000-0000-4000-8000-000000000002"
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private final class Fixture {
        let folder: URL
        let profiles: BrowserProfileStore
        let spaces: BrowserSpaceStore
        let archive: BrowserArchiveStore
        let favicons: BrowserFaviconStore
        let linkRouting: BrowserLinkRoutingStore
        var histories: [UUID: BrowserHistoryStore] = [:]

        @MainActor
        init() {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("SopranoWebImporter-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            profiles = BrowserProfileStore(url: folder.appendingPathComponent("profiles.json"))
            spaces = BrowserSpaceStore(url: folder.appendingPathComponent("spaces.json"), profiles: profiles.profiles)
            archive = BrowserArchiveStore(url: folder.appendingPathComponent("archive.json"))
            favicons = BrowserFaviconStore(directory: folder.appendingPathComponent("Favicons", isDirectory: true))
            linkRouting = BrowserLinkRoutingStore(url: folder.appendingPathComponent("link-routing.json"))
        }

        @MainActor
        var stores: BrowserImporter.Stores {
            BrowserImporter.Stores(
                profiles: profiles,
                spaces: spaces,
                archive: archive,
                favicons: favicons,
                linkRouting: linkRouting,
                history: { [self] profile in
                    if let store = histories[profile.id] { return store }
                    let store = BrowserHistoryStore(directory: profile.directory(in: folder))
                    histories[profile.id] = store
                    return store
                }
            )
        }

        @MainActor
        var context: BrowserImportPlanner.Context {
            BrowserImportPlanner.Context(
                profiles: profiles.profiles,
                spaces: spaces.list,
                archiveIDs: Set(archive.entries.map(\.id)),
                routingRules: linkRouting.rules,
                targetSpaceID: spaces.firstSpace(ofProfile: BrowserProfile.defaultID)?.id
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func link(_ url: String, _ title: String = "", id: String? = nil) -> BrowserImportedLink {
        BrowserImportedLink(sourceID: id, url: url, title: title, addedAt: date)
    }

    private func visits() -> [BrowserImportedVisit] {
        (0..<5).map { BrowserImportedVisit(url: "https://h\($0 % 3).example/", title: "H", visitedAt: date.addingTimeInterval(Double($0) * 60)) }
    }

    private func arc() -> BrowserArcImport {
        BrowserArcImport(
            profiles: [
                BrowserImportedProfile(key: "Default", displayName: "Person 1", directory: nil),
                BrowserImportedProfile(key: "Profile 1", displayName: "Work person", directory: nil),
            ],
            spaces: [
                BrowserImportedSpace(
                    sourceID: spaceA, name: "Home", emoji: "🦅", iconName: nil, color: nil, profileKey: "Default",
                    pinned: [.link(link("https://a.example/", "A"))],
                    today: [link("https://today.example/", "Today")]
                ),
                BrowserImportedSpace(
                    sourceID: spaceB, name: "Work", emoji: nil, iconName: nil,
                    color: BrowserImportedColor(red: -0.385, green: 0.847, blue: 0.338, alpha: 1),
                    profileKey: "Profile 1",
                    pinned: [.folder(BrowserImportedFolder(name: "Docs", children: [.link(link("https://docs.example/", "Docs"))]))],
                    today: []
                ),
                BrowserImportedSpace(
                    sourceID: spaceC, name: "Side", emoji: nil, iconName: nil, color: nil, profileKey: "Profile 1",
                    pinned: [.link(link("https://side.example/"))], today: []
                ),
            ],
            favorites: [
                BrowserImportedFavorites(profileKey: "Default", links: (1...14).map { link("https://fav\($0).example/", "Fav \($0)") }),
            ],
            archive: [
                BrowserImportedArchiveItem(link: link("https://archived.example/", "Archived", id: archivedB),
                                           spaceSourceID: spaceB, archivedAt: date, reason: .manual),
                BrowserImportedArchiveItem(link: link("https://little.example/", "Little", id: archivedLittle),
                                           spaceSourceID: nil, archivedAt: date, reason: .auto),
            ],
            routingRules: [
                BrowserImportedRoutingRule(match: .contains, value: "meet.example", destination: .space(sourceID: nil)),
                BrowserImportedRoutingRule(match: .prefix, value: "https://x.example/", destination: .space(sourceID: spaceB)),
                BrowserImportedRoutingRule(match: .contains, value: "zoom.example", destination: .littleArc),
            ],
            favicons: [:],
            historyFiles: [:]
        )
    }

    private func plan(_ fixture: Fixture) -> BrowserImportPlan {
        var plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: fixture.context)
        plan.history = [BrowserImportPlan.History(
            id: "test", title: "History", profileKey: "Profile 1", source: .visits(visits()), visitCount: 5, isIncluded: true
        )]
        return plan
    }

    private func run(_ plan: BrowserImportPlan, _ fixture: Fixture) async -> BrowserImporter.Summary {
        await withCheckedContinuation { continuation in
            BrowserImporter(stores: fixture.stores).run(
                plan,
                cancellation: BrowserImportCancellation(),
                progress: { _ in },
                completion: { continuation.resume(returning: $0) }
            )
        }
    }

    @Test func anArcImportMakesProfilesSpacesFavoritesArchiveAndRules() async throws {
        let fixture = Fixture()
        let summary = await run(plan(fixture), fixture)

        #expect(summary.profilesCreated == ["Work"])
        let work = try #require(fixture.profiles.profile(named: "Work"))
        #expect(work.importedFrom == "arc:Profile 1")
        // The new profile's own Space became its first imported Space;
        // no second one was added for it.
        let workSpaces = fixture.spaces.spaces(ofProfile: work.id)
        #expect(workSpaces.map(\.name) == ["Work", "Side"])
        #expect(workSpaces.map(\.importedFrom) == [spaceB, spaceC])
        #expect(workSpaces.first?.color == .green)
        #expect(fixture.spaces.pins(inSpace: workSpaces[0].id).map(\.url) == ["https://docs.example/"])

        // Arc's Default Space joins Default next to its own Space.
        let defaults = fixture.spaces.spaces(ofProfile: BrowserProfile.defaultID)
        #expect(defaults.count == 2)
        let home = try #require(defaults.first { $0.importedFrom == spaceA })
        #expect(home.icon == .emoji("🦅"))
        #expect(summary.spacesCreated == 3)
        #expect(summary.firstSpaceID == home.id)
        #expect(summary.todayTabs.map { $0.spaceID } == [home.id])

        // 12 favorites; the 2 past the limit end Home's pins.
        #expect(fixture.spaces.favorites(ofProfile: BrowserProfile.defaultID).count == BrowserFavorites.limit)
        #expect(summary.favoritesPinned == 2)
        #expect(fixture.spaces.pins(inSpace: home.id).map(\.url).suffix(2) == ["https://fav13.example/", "https://fav14.example/"])

        // Archive: the Space's entry in its profile, Little Arc's in Default's first Space.
        #expect(summary.archiveAdded == 2)
        let fromSpaceID = try #require(UUID(uuidString: archivedB))
        let fromSpace = try #require(fixture.archive.entry(id: fromSpaceID))
        #expect(fromSpace.profileID == work.id)
        #expect(fromSpace.spaceID == workSpaces[0].id)
        #expect(fromSpace.reason == .imported)
        let littleID = try #require(UUID(uuidString: archivedLittle))
        let little = try #require(fixture.archive.entry(id: littleID))
        #expect(little.profileID == BrowserProfile.defaultID)
        #expect(little.spaceID == defaults[0].id)

        // Rules: the most recent Space and Work; Little Arc's is dropped.
        #expect(summary.rulesAdded == 2)
        #expect(fixture.linkRouting.rules.map(\.destination) == [.mostRecentSpace, .space(workSpaces[0].id)])

        #expect(summary.history.map(\.count) == [BrowserHistoryImportCount(added: 5, skipped: 0)])
        #expect(fixture.histories[work.id]?.visitCount() == 5)
    }

    @Test func importingAgainAddsNothing() async throws {
        let fixture = Fixture()
        _ = await run(plan(fixture), fixture)
        let spaces = fixture.spaces.spaces
        let profiles = fixture.profiles.profiles

        let again = plan(fixture)
        #expect(again.spaces.allSatisfy { $0.isSkipped })
        let summary = await run(again, fixture)
        #expect(summary.profilesCreated.isEmpty)
        #expect(summary.spacesCreated == 0)
        #expect(summary.spacesSkipped == 3)
        #expect(summary.favoritesAdded == 0)
        #expect(summary.favoritesPinned == 0)
        #expect(summary.archiveAdded == 0)
        #expect(summary.rulesAdded == 0)
        #expect(summary.todayTabs.isEmpty)
        #expect(summary.history.map(\.count) == [BrowserHistoryImportCount(added: 0, skipped: 5)])
        #expect(fixture.spaces.spaces == spaces)
        #expect(fixture.profiles.profiles == profiles)
    }

    @Test func uncheckedItemsStayOut() async throws {
        let fixture = Fixture()
        var plan = plan(fixture)
        BrowserImportChecklist.set(.space(spaceB), included: false, in: &plan)
        BrowserImportChecklist.set(.space(spaceC), included: false, in: &plan)
        BrowserImportChecklist.set(.history("test"), included: false, in: &plan)
        BrowserImportChecklist.set(.routing, included: false, in: &plan)
        let summary = await run(plan, fixture)
        // Nothing of Profile 1 was imported, so no profile was made; its
        // archived tab goes to Default's Archive.
        #expect(summary.profilesCreated.isEmpty)
        #expect(fixture.profiles.profiles.count == 1)
        // Its archived tab waits for the profile; only Little Arc's goes to Default.
        #expect(fixture.archive.entries.map(\.url) == ["https://little.example/"])
        #expect(fixture.archive.entries.first?.profileID == BrowserProfile.defaultID)
        #expect(fixture.linkRouting.rules.isEmpty)
        #expect(summary.history.isEmpty)
    }

    @Test func rulesForUncheckedSpacesAreNotCountedAndReimportsKeepArcsOrder() async throws {
        let fixture = Fixture()
        var plan = plan(fixture)
        BrowserImportChecklist.set(.space(spaceB), included: false, in: &plan)
        #expect(plan.importableRuleCount == 1)
        BrowserImportChecklist.set(.history("test"), included: false, in: &plan)
        _ = await run(plan, fixture)
        #expect(fixture.linkRouting.rules.map(\.value) == ["meet.example"])

        // Work's Space comes in later; its rule goes where Arc has it.
        let user = BrowserLinkRoutingRule(match: .contains, value: "mine.example", destination: .mostRecentSpace)
        fixture.linkRouting.add([user])
        let summary = await run(self.plan(fixture), fixture)
        #expect(summary.rulesAdded == 1)
        #expect(fixture.linkRouting.rules.map(\.value) == ["meet.example", "https://x.example/", "mine.example"])
    }

    @Test func historyOfAProfileThatVanishedIsSkipped() async throws {
        let fixture = Fixture()
        let gone = BrowserProfile(name: "Gone", color: .gray, importedFrom: BrowserImportPlanner.arcProfileSource("Profile 1"))
        var context = fixture.context
        context.profiles.append(gone)
        var plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context)
        plan.history = [BrowserImportPlan.History(
            id: "test", title: "History", profileKey: "Profile 1", source: .visits(visits()), visitCount: 5, isIncluded: true
        )]
        #expect(plan.profile(key: "Profile 1")?.target == .existing(gone.id))
        let summary = await run(plan, fixture)
        #expect(summary.history.isEmpty)
        #expect(fixture.histories.isEmpty || fixture.histories.values.allSatisfy { $0.visitCount() == 0 })
    }

    @Test func bookmarkFoldersGoToTheTargetSpaceOnce() async throws {
        let fixture = Fixture()
        let nodes: [BrowserImportedNode] = [
            .folder(BrowserImportedFolder(name: "Bar", children: [.link(link("https://c.example/", "C"))])),
            .link(link("https://d.example/", "D")),
        ]
        let first = await run(BrowserImportPlanner.bookmarksFile(nodes, name: "bookmarks.html", context: fixture.context), fixture)
        #expect(first.pinsAdded == 2)
        #expect(first.foldersAdded == 2)
        let space = try #require(fixture.spaces.firstSpace(ofProfile: BrowserProfile.defaultID))
        #expect(fixture.spaces.pinTree(inSpace: space.id).root.children.map(\.title) == ["bookmarks"])

        let again = BrowserImportPlanner.bookmarksFile(nodes, name: "bookmarks.html", context: fixture.context)
        #expect(again.folders.first?.alreadyThere == true)
        let second = await run(again, fixture)
        #expect(second.pinsAdded == 0)
        #expect(fixture.spaces.pinTree(inSpace: space.id).root.children.count == 1)
    }
}
