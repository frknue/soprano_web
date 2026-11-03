@testable import SopranoWeb
import AppKit
import Testing

/// The plan step: an Arc import's mapping onto profiles and Spaces, what a
/// re-import skips, favorites past the limit, the Archive without a Space,
/// History-only profiles, colors and the Chrome/Safari/file folders.
struct BrowserImportPlanTests {
    private let spaceA = "0A000000-0000-4000-8000-000000000001"
    private let spaceB = "0A000000-0000-4000-8000-000000000002"
    private let spaceC = "0A000000-0000-4000-8000-000000000003"
    private let archivedA = "A1000000-0000-4000-8000-000000000001"
    private let archivedLittle = "A1000000-0000-4000-8000-000000000002"
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func link(_ url: String, _ title: String = "", id: String? = nil) -> BrowserImportedLink {
        BrowserImportedLink(sourceID: id, url: url, title: title, addedAt: date)
    }

    /// Default (Person 1) with a Space and 14 favorites, Profile 1 with
    /// two Spaces (first named "Work"), Profile 2 with History only.
    private func arc() -> BrowserArcImport {
        let history = URL(fileURLWithPath: "/tmp/History")
        return BrowserArcImport(
            profiles: [
                BrowserImportedProfile(key: "Default", displayName: "Person 1", directory: nil),
                BrowserImportedProfile(key: "Profile 1", displayName: "Work person", directory: nil),
                BrowserImportedProfile(key: "Profile 2", displayName: "Private", directory: nil),
            ],
            spaces: [
                BrowserImportedSpace(
                    sourceID: spaceA, name: "Home", emoji: "🦅", iconName: nil,
                    color: BrowserImportedColor(red: 0.424, green: 0.729, blue: 0.851, alpha: 1),
                    profileKey: "Default",
                    pinned: [.link(link("https://a.example/", "A"))],
                    today: [link("https://today.example/", "Today")]
                ),
                BrowserImportedSpace(
                    sourceID: spaceB, name: "  Work ", emoji: nil, iconName: "planet",
                    color: BrowserImportedColor(red: -0.385, green: 0.847, blue: 0.338, alpha: 1),
                    profileKey: "Profile 1",
                    pinned: [
                        .folder(BrowserImportedFolder(name: "Docs", children: [
                            .link(link("https://docs.example/", "Docs")),
                            .folder(BrowserImportedFolder(name: "Inner", children: [.link(link("https://inner.example/"))])),
                        ])),
                        .link(link("https://b.example/", "B")),
                    ],
                    today: []
                ),
                BrowserImportedSpace(
                    sourceID: spaceC, name: "Side", emoji: nil, iconName: nil, color: nil,
                    profileKey: "Profile 1", pinned: [], today: []
                ),
            ],
            favorites: [
                BrowserImportedFavorites(
                    profileKey: "Default",
                    links: (1...14).map { link("https://fav\($0).example/", "Fav \($0)") }
                ),
            ],
            archive: [
                BrowserImportedArchiveItem(
                    link: link("https://archived.example/", "Archived", id: archivedA),
                    spaceSourceID: spaceB, archivedAt: date, reason: .manual
                ),
                BrowserImportedArchiveItem(
                    link: link("https://little.example/", "Little", id: archivedLittle),
                    spaceSourceID: nil, archivedAt: date, reason: .auto
                ),
            ],
            routingRules: [
                BrowserImportedRoutingRule(match: .contains, value: "meet.example", destination: .space(sourceID: nil)),
                BrowserImportedRoutingRule(match: .equals, value: "https://x.example/", destination: .space(sourceID: spaceB)),
                BrowserImportedRoutingRule(match: .contains, value: "zoom.example", destination: .littleArc),
            ],
            favicons: [:],
            historyFiles: ["Default": history, "Profile 1": history, "Profile 2": history]
        )
    }

    private func context(
        profiles: [BrowserProfile] = [.defaultProfile],
        spaces: BrowserSpaceList? = nil,
        archiveIDs: Set<UUID> = []
    ) -> BrowserImportPlanner.Context {
        var list = spaces ?? BrowserSpaceList()
        if spaces == nil {
            list.reconcile(with: profiles)
        }
        return BrowserImportPlanner.Context(
            profiles: profiles,
            spaces: list,
            archiveIDs: archiveIDs,
            routingRules: [],
            targetSpaceID: list.space(ofProfile: BrowserProfile.defaultID)?.id
        )
    }

    // MARK: Arc

    /// Every visit importable and kept.
    private func counts(_ values: [String: Int]) -> [String: BrowserImportSourceData.HistoryCounts] {
        values.mapValues { BrowserImportSourceData.HistoryCounts(visits: $0 + 1, importable: $0, kept: $0) }
    }

    @Test func arcProfilesHaveHomeSpaces() {
        let stores = context()
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: counts(["Default": 10, "Profile 1": 20, "Profile 2": 3]), context: stores)
        #expect(plan.profiles.map(\.key) == ["Default", "Profile 1", "Profile 2"])
        #expect(plan.profiles[0].target == .existing(BrowserProfile.defaultID))
        #expect(plan.profiles[1].target == .new(name: "Work"))
        // No Space: named after its Arc profile.
        #expect(plan.profiles[2].target == .new(name: "Private"))
        #expect(plan.spaces.map(\.isIncluded) == [true, true, true])
        #expect(plan.spaces.map(\.pinCount) == [1, 3, 0])
        #expect(plan.spaces.map(\.folderCount) == [0, 2, 0])
        #expect(plan.spaces[0].icon == .emoji("🦅"))
        // Arc's built-in icon names aren't SF Symbols.
        #expect(plan.spaces[1].icon == BrowserSpaceIcon.none)
        // The untouched Default Space is taken over by Default's first
        // Space; every other Arc Space becomes a Space of its own.
        let defaultSpace = stores.spaces.defaultSpace?.id
        #expect(plan.profiles[0].adoptableSpaceID == defaultSpace)
        #expect(plan.spaces.map { plan.adoptedSpaceID(by: $0) } == [defaultSpace, nil, nil])
        // History and favorites go to each profile's first Space.
        #expect(plan.homeName(ofProfile: "Default") == "“Default”")
        #expect(plan.homeName(ofProfile: "Profile 1") == "“Work”")
        #expect(plan.homeName(ofProfile: "Profile 2") == "new Space “Private”")
    }

    @Test func aDefaultSpaceWithPinsIsNotTakenOver() {
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        let home = list.defaultSpace?.id ?? UUID()
        list.updatePins(in: home) { $0.insert(.pin(BrowserPin(url: "https://mine.example/", title: "Mine")), into: BrowserPinTree.rootID) }
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context(spaces: list))
        #expect(plan.profiles[0].adoptableSpaceID == nil)
        #expect(plan.spaces.allSatisfy { plan.adoptedSpaceID(by: $0) == nil })
        let rows = BrowserImportChecklist.rows(for: plan).filter { $0.section == "Spaces" }
        #expect(rows.allSatisfy { $0.detail.hasSuffix("→ a Space of its own") })
    }

    @Test func historyOnlyProfilesAreOfferedUnchecked() {
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: counts(["Default": 10, "Profile 1": 20, "Profile 2": 3]), context: context())
        #expect(plan.history.map(\.profileKey) == ["Default", "Profile 1", "Profile 2"])
        #expect(plan.history.map(\.visitCount) == [10, 20, 3])
        #expect(plan.history.map(\.isIncluded) == [true, true, false])
        #expect(plan.includedVisitCount == 30)
    }

    @Test func spacesImportedBeforeAreSkippedAndTheirHomeReused() {
        // An earlier import made Work from Arc's Space B, as Profile 1's
        // home (its profile is marked).
        let work = BrowserProfile(name: "Work", color: .green, importedFrom: BrowserImportPlanner.profileSource(.arc, "Profile 1"))
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        let earlier = list.create(name: "Work", color: .green, profileID: work.id, importedFrom: spaceB)
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context(profiles: [.defaultProfile, work], spaces: list))
        #expect(plan.profile(key: "Profile 1")?.target == .existing(work.id))
        #expect(plan.profile(key: "Profile 1")?.adoptableSpaceID == nil)
        #expect(plan.spaces[1].existingSpaceID == earlier?.id)
        #expect(plan.spaces[1].isIncluded == false)
        #expect(plan.spaces[2].isIncluded)
        #expect(BrowserImportChecklist.summary(of: plan).hasPrefix("2 Spaces"))
    }

    @Test func aProfileAnImportMadeIsFoundByItsSource() {
        let earlier = BrowserProfile(name: "Private", color: .gray, importedFrom: BrowserImportPlanner.profileSource(.arc, "Profile 2"))
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context(profiles: [.defaultProfile, earlier]))
        #expect(plan.profile(key: "Profile 2")?.target == .existing(earlier.id))
    }

    @Test func favoritesPastTheLimitAndOnesThereAlreadyAreCounted() {
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        for index in 1...10 {
            // Favorite 1 is there already, so 13 links are new.
            let url = index == 1 ? "https://fav1.example/" : "https://mine\(index).example/"
            list.updateFavorites(ofProfile: BrowserProfile.defaultID) { $0.add(BrowserPin(url: url, title: "\(index)")) }
        }
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context(spaces: list))
        let favorites = plan.favorites[0]
        #expect(favorites.alreadyThere == 1)
        #expect(favorites.links.count == 13)
        #expect(favorites.capacity == 2)
        #expect(favorites.toFavorites == 2)
        #expect(favorites.overflow == 11)
    }

    @Test func archiveCountsNewEntriesAndThoseWithoutASpace() throws {
        let known = try #require(UUID(uuidString: archivedA))
        let plan = BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context(archiveIDs: [known]))
        let archive = try #require(plan.archive)
        #expect(archive.items.count == 2)
        #expect(archive.newCount == 1)
        #expect(archive.spacelessCount == 1)
        // Arc's item id is the entry id; a non-UUID id gets a stable one.
        #expect(BrowserImportPlanner.archiveEntryID(for: archive.items[0]) == known)
        let odd = BrowserImportedArchiveItem(link: link("https://odd.example/", id: "not-a-uuid"), spaceSourceID: nil, archivedAt: date, reason: .unknown)
        #expect(BrowserImportPlanner.archiveEntryID(for: odd) == BrowserImportPlanner.archiveEntryID(for: odd))
    }

    @Test func routingRulesForLittleArcAreNotImportable() throws {
        let routing = try #require(BrowserImportPlanner.arc(arc(), historyCounts: [:], context: context()).routing)
        #expect(routing.importable == 2)
        #expect(routing.unsupported == 1)
    }

    @Test func arcsDefaultDestinationSetsWhereOtherLinksOpen() throws {
        var data = arc()
        data.defaultLinkDestination = .littleArc
        let plan = BrowserImportPlanner.arc(data, historyCounts: [:], context: context())
        #expect(plan.routing?.otherLinks == .littleArc)
        let row = try #require(BrowserImportChecklist.rows(for: plan).first { $0.item == .routing })
        #expect(row.detail.hasSuffix("· other links open in Little Arc"))
        #expect(BrowserImportChecklist.summary(of: plan).hasSuffix("links to Little Arc"))

        // A Space destination means the most recent window; without rules
        // the row is still there, for the choice alone.
        data.routingRules = []
        data.defaultLinkDestination = .space(sourceID: nil)
        let alone = BrowserImportPlanner.arc(data, historyCounts: [:], context: context())
        #expect(alone.routing?.otherLinks == .mostRecentWindow)
        #expect(alone.routing?.isIncluded == true)
        #expect(BrowserImportChecklist.rows(for: alone).first { $0.item == .routing }?.isEnabled == true)

        data.defaultLinkDestination = nil
        #expect(BrowserImportPlanner.arc(data, historyCounts: [:], context: context()).routing == nil)
    }

    @Test func checklistTogglesItems() {
        var plan = BrowserImportPlanner.arc(arc(), historyCounts: counts(["Default": 10, "Profile 2": 3]), context: context())
        let rows = BrowserImportChecklist.rows(for: plan)
        #expect(rows.first?.section == "Spaces")
        #expect(rows.contains { $0.item == .history("arc:Profile 2") && !$0.isChecked })
        BrowserImportChecklist.set(.history("arc:Profile 2"), included: true, in: &plan)
        BrowserImportChecklist.set(.space(spaceA), included: false, in: &plan)
        #expect(plan.history.first { $0.profileKey == "Profile 2" }?.isIncluded == true)
        #expect(plan.spaces[0].isIncluded == false)
        #expect(plan.includedVisitCount == 13)
    }

    // MARK: Colors

    @Test func colorsMatchTheNearestFolioHueAfterConvertingExtendedSRGB() {
        func match(_ red: Double, _ green: Double, _ blue: Double) -> BrowserProfileColor? {
            BrowserImportColorMatch.profileColor(for: BrowserImportedColor(red: red, green: green, blue: blue, alpha: 1))
        }
        // Arc's vivid green, `red` far below 0: green, not clamped to teal.
        #expect(match(-0.38497164845466614, 0.8467978239059448, 0.33840304613113403) == .green)
        #expect(match(0.424, 0.729, 0.851) == .blue)
        #expect(match(0.768, 0.521, 0.683) == .red)
        #expect(match(0.95, 0.8, 0.2) == .yellow)
        #expect(match(0.1, 0.6, 0.6) == .cyan)
        #expect(match(0.584, 0.587, 0.692) == .gray)
        #expect(match(1.2, 1.1, 1.15) == .gray)
        #expect(BrowserImportColorMatch.profileColor(for: nil) == nil)
    }

    // MARK: Chrome, Safari, files

    @Test func aSingleChromeProfileGoesIntoTheTargetSpaceAndSkipsPinsThereAlready() {
        let nodes: [BrowserImportedNode] = [
            .link(link("https://c.example/")),
            .folder(BrowserImportedFolder(name: "Work", children: [.link(link("https://w.example/"))])),
        ]
        let profiles = [
            BrowserImportSourceData.ChromeProfile(
                profile: BrowserImportedProfile(key: "Default", displayName: "Me", directory: nil),
                bookmarks: nodes, historyFile: URL(fileURLWithPath: "/tmp/History"),
                historyCounts: BrowserImportSourceData.HistoryCounts(visits: 9, importable: 7, kept: 5),
                cookiesFile: URL(fileURLWithPath: "/tmp/Cookies"), cookieCount: 4
            ),
        ]
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        let plan = BrowserImportPlanner.chromium(.chrome, profiles, context: context(spaces: list))
        #expect(plan.profiles.isEmpty)
        #expect(plan.folders.map(\.wrapsInFolder) == [false])
        #expect(plan.folders.map(\.profileKey) == [nil])
        #expect(plan.history.map(\.visitCount) == [5])
        #expect(plan.cookies.map(\.keychainService) == ["Chrome Safe Storage"])
        #expect(plan.includedCookieCount == 4)
        #expect(BrowserImportChecklist.summary(of: plan) == "2 pins · 5 visits · 4 cookies")
        #expect(BrowserImportChecklist.rows(for: plan).first?.detail == "2 pins · 1 folder → pinned in the chosen Space")

        // The pin is there, the folder isn't: still to import.
        let spaceID = list.spaces[0].id
        list.updatePins(in: spaceID) { $0.insert(.pin(BrowserPin(url: "https://c.example/", title: "C")), into: BrowserPinTree.rootID, at: nil) }
        #expect(BrowserImportPlanner.chromium(.chrome, profiles, context: context(spaces: list)).folders.map(\.isIncluded) == [true])
        // A same-named folder without the pin inside doesn't count.
        list.updatePins(in: spaceID) { $0.insert(.folder(BrowserPinFolder(name: "Work")), into: BrowserPinTree.rootID, at: nil) }
        #expect(BrowserImportPlanner.chromium(.chrome, profiles, context: context(spaces: list)).folders.map(\.isIncluded) == [true])
        // Every address pinned: skipped.
        list.updatePins(in: spaceID) { $0.insert(.pin(BrowserPin(url: "https://w.example/", title: "W")), into: BrowserPinTree.rootID, at: nil) }
        let again = BrowserImportPlanner.chromium(.chrome, profiles, context: context(spaces: list))
        #expect(again.folders.map(\.isIncluded) == [false])
        #expect(BrowserImportChecklist.rows(for: again).first?.detail == "Pinned there already; skipped")

        let file = BrowserImportPlanner.bookmarksFile(nodes, name: "export.html", context: context())
        #expect(file.folders.map(\.name) == ["export"])
    }

    /// Aside's profiles: Valkental matches a Space of that name, Hustle was
    /// imported before (its profile is marked), Datora gets a new Space, and
    /// a `Default` matching nothing lands in the Default Space.
    @Test func severalChromiumProfilesEachGetAHomeSpace() throws {
        let nodes: [BrowserImportedNode] = [.link(link("https://c.example/"))]
        func profile(_ key: String, _ name: String, cookies: Int = 0) -> BrowserImportSourceData.ChromeProfile {
            BrowserImportSourceData.ChromeProfile(
                profile: BrowserImportedProfile(key: key, displayName: name, directory: nil),
                bookmarks: nodes, historyFile: URL(fileURLWithPath: "/tmp/\(key)/History"),
                historyCounts: BrowserImportSourceData.HistoryCounts(visits: 3, importable: 3, kept: 3),
                cookiesFile: URL(fileURLWithPath: "/tmp/\(key)/Cookies"), cookieCount: cookies
            )
        }
        let valkental = BrowserProfile(name: "Valkental", color: .cyan)
        let hustle = BrowserProfile(name: "Side", color: .green, importedFrom: BrowserImportPlanner.profileSource(.aside, "Profile 1"))
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        let valkentalSpace = list.create(name: "valkental ", color: .cyan, profileID: valkental.id)
        list.create(name: "Side", color: .green, profileID: hustle.id)
        let stores = context(profiles: [.defaultProfile, valkental, hustle], spaces: list)

        let plan = BrowserImportPlanner.chromium(.aside, [
            profile("Default", "Valkental", cookies: 7),
            profile("Profile 1", "Hustle", cookies: 2),
            profile("Profile 3", "Datora"),
        ], context: stores)
        #expect(plan.profiles.map(\.target) == [.existing(valkental.id), .existing(hustle.id), .new(name: "Datora")])
        #expect(plan.folders.map(\.wrapsInFolder) == [false, false, false])
        #expect(plan.folders.map(\.profileKey) == ["Default", "Profile 1", "Profile 3"])
        #expect(plan.history.map(\.profileKey) == ["Default", "Profile 1", "Profile 3"])
        #expect(plan.cookies.map(\.id) == ["aside:Default", "aside:Profile 1", "aside:Profile 3"])
        #expect(plan.cookies.map(\.isIncluded) == [true, true, false])
        #expect(plan.homeName(ofProfile: "Profile 3") == "new Space “Datora”")

        // The sheet's Space menu doesn't apply: every profile has its home.
        var retargeted = plan
        BrowserImportPlanner.retarget(&retargeted, to: try #require(valkentalSpace).id, spaces: list)
        #expect(retargeted.targetSpaceID == plan.targetSpaceID)

        let fresh = BrowserImportPlanner.chromium(.chrome, [profile("Default", "Person 1"), profile("Profile 1", "Work")], context: context())
        #expect(fresh.profiles.map(\.target) == [.existing(BrowserProfile.defaultID), .new(name: "Work")])
    }

    /// Two profiles never share a home: a second "Work" gets a new Space,
    /// and `Default` doesn't fall back onto a Space another profile took,
    /// nor may a name match take the Space an earlier import marked.
    @Test func chromiumProfilesNeverShareAHome() {
        func profile(_ key: String, _ name: String) -> BrowserImportSourceData.ChromeProfile {
            BrowserImportSourceData.ChromeProfile(
                profile: BrowserImportedProfile(key: key, displayName: name, directory: nil),
                bookmarks: [], historyFile: nil,
                historyCounts: BrowserImportSourceData.HistoryCounts(visits: 0, importable: 0, kept: 0)
            )
        }
        let work = BrowserProfile(name: "Work", color: .green)
        let marked = BrowserProfile(name: "Side", color: .red, importedFrom: BrowserImportPlanner.profileSource(.chrome, "Profile 2"))
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        list.create(name: "Work", color: .green, profileID: work.id)
        list.create(name: "Side", color: .red, profileID: marked.id)
        let stores = context(profiles: [.defaultProfile, work, marked], spaces: list)

        let plan = BrowserImportPlanner.chromium(.chrome, [
            profile("Profile 1", "Work"),
            profile("Profile 3", "work"),
            profile("Profile 4", "Side"),
            profile("Profile 5", "Default"),
            profile("Default", "Person 1"),
            profile("Profile 2", "Renamed"),
        ], context: stores)
        #expect(plan.profiles.map(\.target) == [
            .existing(work.id),
            .new(name: "work"),
            .new(name: "Side"),
            .existing(BrowserProfile.defaultID),
            .new(name: "Person 1"),
            .existing(marked.id),
        ])
    }

    /// A name match wins over the `Default` fallback whatever the
    /// browser's profile order; a profile with nothing to import makes no
    /// Space (its empty History is unchecked).
    @Test func nameMatchesComeBeforeTheDefaultFallbackAndEmptyHistoryStaysOut() {
        func profile(_ key: String, _ name: String, visits: Int) -> BrowserImportSourceData.ChromeProfile {
            BrowserImportSourceData.ChromeProfile(
                profile: BrowserImportedProfile(key: key, displayName: name, directory: nil),
                bookmarks: [], historyFile: URL(fileURLWithPath: "/tmp/\(key)/History"),
                historyCounts: BrowserImportSourceData.HistoryCounts(visits: visits, importable: visits, kept: visits)
            )
        }
        let plan = BrowserImportPlanner.chromium(.aside, [
            profile("Default", "Valkental", visits: 4),
            profile("Profile 1", "Default", visits: 0),
        ], context: context())
        #expect(plan.profiles.map(\.target) == [.new(name: "Valkental"), .existing(BrowserProfile.defaultID)])
        #expect(plan.history.map(\.isIncluded) == [true, false])
    }

    /// A browser down to one profile still goes to that profile's home
    /// from an earlier import, not to the Space menu's.
    @Test func aSingleProfileWithAnEarlierHomeKeepsIt() {
        let hustle = BrowserProfile(name: "Hustle", color: .green, importedFrom: BrowserImportPlanner.profileSource(.aside, "Profile 1"))
        var list = BrowserSpaceList()
        list.reconcile(with: [.defaultProfile])
        list.create(name: "Hustle", color: .green, profileID: hustle.id)
        let plan = BrowserImportPlanner.chromium(.aside, [
            BrowserImportSourceData.ChromeProfile(
                profile: BrowserImportedProfile(key: "Profile 1", displayName: "Hustle", directory: nil),
                bookmarks: [.link(link("https://h.example/"))], historyFile: nil,
                historyCounts: BrowserImportSourceData.HistoryCounts(visits: 0, importable: 0, kept: 0)
            ),
        ], context: context(profiles: [.defaultProfile, hustle], spaces: list))
        #expect(plan.profiles.map(\.target) == [.existing(hustle.id)])
        #expect(plan.folders.map(\.profileKey) == ["Profile 1"])
    }

    @Test func safariHistoryIsOneVisitPerPageAtItsLastVisit() throws {
        let export = BrowserSafariExport(
            bookmarks: [],
            histories: [BrowserSafariExport.History(profileName: nil, visits: [
                BrowserImportedVisit(url: "https://s.example/", title: "S", visitedAt: date, visitCount: 40),
            ])]
        )
        let plan = BrowserImportPlanner.safari(export, name: "Safari.zip", context: context())
        #expect(plan.folders.isEmpty)
        guard case let .visits(visits) = try #require(plan.history.first).source else {
            Issue.record("Safari History should be read visits")
            return
        }
        #expect(visits.map(\.visitCount) == [1])
        #expect(visits.map(\.visitedAt) == [date])
    }
}
