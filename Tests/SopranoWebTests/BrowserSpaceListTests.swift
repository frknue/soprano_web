@testable import SopranoWeb
import AppKit
import Testing

struct BrowserSpaceListTests {
    private let work = BrowserProfile(name: "Work", color: .green)

    private func pin(_ title: String) -> BrowserPin {
        BrowserPin(url: "https://\(title.lowercased()).example/", title: title)
    }

    // MARK: Spaces

    @Test func everySpaceHasAProfileOfItsOwn() throws {
        var list = BrowserSpaceList()
        let home = list.ensureSpace(for: .defaultProfile)
        #expect(list.defaultSpace == home)
        // A second Space can't share a profile.
        #expect(list.create(name: "Reading", color: .cyan, profileID: BrowserProfile.defaultID) == nil)
        let readingSpace = list.create(name: "Reading", color: .cyan, profileID: work.id)
        let reading = try #require(readingSpace)
        #expect(list.space(ofProfile: work.id) == reading)
        #expect(list.create(name: "Second", color: .red, profileID: work.id) == nil)
        list.deleteSpace(ofProfile: work.id)
        #expect(list.spaces.map(\.id) == [home.id])
    }

    @Test func isolateSeparatesSpacesThatShareAProfileOnce() throws {
        let shared = UUID()
        let first = BrowserSpace(name: "Work", color: .green, profileID: shared)
        let second = BrowserSpace(name: "Side", color: .red, profileID: shared)
        let third = BrowserSpace(name: "Home", color: .blue, profileID: BrowserProfile.defaultID)
        let fourth = BrowserSpace(name: "Reading", color: .cyan, profileID: BrowserProfile.defaultID)
        var list = BrowserSpaceList(spaces: [first, second, third, fourth])
        let separations = list.isolate(known: [shared, BrowserProfile.defaultID])
        // The first Space keeps the profile; every further one gets a new
        // profile whose id is its own.
        #expect(separations == [
            BrowserSpaceList.Separation(spaceID: second.id, from: shared),
            BrowserSpaceList.Separation(spaceID: fourth.id, from: BrowserProfile.defaultID),
        ])
        #expect(list.spaces.map(\.profileID) == [shared, second.id, BrowserProfile.defaultID, fourth.id])
        #expect(list.defaultSpace?.id == third.id)
        // Once their profiles exist, a second pass finds nothing.
        #expect(list.isolate(known: [shared, BrowserProfile.defaultID, second.id, fourth.id]).isEmpty)
    }

    @Test func isolateFinishesAnInterruptedSeparation() {
        // `spaces.json` was written but `profiles.json` wasn't: the Space's
        // profile (its own id) is missing, so it is reported again and
        // `reconcile` keeps the Space once that profile is made.
        let id = UUID()
        let separated = BrowserSpace(id: id, name: "Side", color: .red, profileID: id)
        let orphan = BrowserSpace(name: "Gone", color: .gray, profileID: UUID())
        var list = BrowserSpaceList(spaces: [separated, orphan])
        let separations = list.isolate(known: [BrowserProfile.defaultID])
        #expect(separations == [BrowserSpaceList.Separation(spaceID: id, from: nil)])
        list.reconcile(with: [.defaultProfile, BrowserProfile(id: id, name: "Side", color: .red)])
        #expect(list.space(id: id) != nil)
        #expect(list.space(id: orphan.id) == nil)
    }

    @Test func ensureSpaceNamesItAfterTheProfileOnce() {
        var list = BrowserSpaceList()
        let first = list.ensureSpace(for: work)
        #expect(first.name == "Work")
        #expect(first.color == .green)
        #expect(first.icon == .none)
        #expect(first.profileID == work.id)
        #expect(first.pinned.isEmpty)
        let again = list.ensureSpace(for: work)
        #expect(again == first)
        #expect(list.spaces.count == 1)
    }

    @Test func reconcileGivesEveryProfileASpaceAndDropsOrphans() throws {
        var list = BrowserSpaceList()
        let orphanProfile = UUID()
        let orphanSpace = list.create(name: "Gone", color: .gray, profileID: orphanProfile)
        let orphan = try #require(orphanSpace)
        let favorite = pin("A")
        list.updateFavorites(ofProfile: orphanProfile) { $0.add(favorite) }
        let changed = list.reconcile(with: [.defaultProfile, work])
        #expect(changed)
        #expect(list.space(id: orphan.id) == nil)
        #expect(list.favorites.isEmpty)
        #expect(list.spaces.map(\.name) == ["Default", "Work"])
        let changedAgain = list.reconcile(with: [.defaultProfile, work])
        #expect(!changedAgain)
    }

    @Test func deletingAProfilesSpaceTakesItsFavorites() throws {
        var list = BrowserSpaceList()
        list.ensureSpace(for: .defaultProfile)
        list.ensureSpace(for: work)
        let a = pin("A")
        let b = pin("B")
        list.updateFavorites(ofProfile: work.id) { $0.add(a) }
        list.updateFavorites(ofProfile: BrowserProfile.defaultID) { $0.add(b) }

        list.deleteSpace(ofProfile: work.id)
        #expect(list.spaces.map(\.profileID) == [BrowserProfile.defaultID])
        #expect(list.favorites(ofProfile: work.id).isEmpty)
        #expect(list.favorites(ofProfile: BrowserProfile.defaultID).items.map(\.title) == ["B"])
    }

    @Test func spacesReorderByDropGapAndRenameRefusesBlank() throws {
        var list = BrowserSpaceList()
        let aSpace = list.create(name: "A", color: .blue, profileID: UUID())
        let a = try #require(aSpace)
        let bSpace = list.create(name: " ", color: .blue, profileID: UUID())
        let b = try #require(bSpace)
        let cSpace = list.create(name: "C", color: .blue, profileID: UUID())
        let c = try #require(cSpace)
        #expect(b.name == "Space")
        list.move(a.id, to: 3)
        #expect(list.spaces.map(\.id) == [b.id, c.id, a.id])
        list.move(a.id, to: 0)
        #expect(list.spaces.map(\.id) == [a.id, b.id, c.id])
        let blank = list.rename(c.id, to: "  ")
        let renamed = list.rename(c.id, to: " Cee ")
        #expect(!blank && renamed)
        #expect(list.space(id: c.id)?.name == "Cee")
        list.setIcon(c.id, .emoji("🚀"))
        list.setColor(c.id, .red)
        #expect(list.space(id: c.id)?.icon == .emoji("🚀"))
        #expect(list.space(id: c.id)?.color == .red)
        let duplicate = list.create(name: "Dup", color: .blue, profileID: UUID(), id: a.id)
        #expect(duplicate == nil)
    }

    @Test func eachSpaceHasItsOwnPinnedTree() throws {
        var list = BrowserSpaceList()
        let aSpace = list.create(name: "A", color: .blue, profileID: work.id)
        let a = try #require(aSpace)
        let bSpace = list.create(name: "B", color: .blue, profileID: UUID())
        let b = try #require(bSpace)
        let shared = pin("Shared")
        // The same pin id may sit in two Spaces' trees, once in each.
        let results = [
            list.updatePins(in: a.id) { $0.insert(.pin(shared), into: BrowserPinTree.rootID) },
            list.updatePins(in: b.id) { $0.insert(.pin(shared), into: BrowserPinTree.rootID) },
            list.updatePins(in: a.id) { $0.insert(.pin(shared), into: BrowserPinTree.rootID) },
            list.updatePins(in: UUID()) { _ in true },
        ]
        #expect(results == [true, true, false, false])
        #expect(list.space(id: a.id)?.pinned.entries().count == 1)
        #expect(list.space(id: b.id)?.pinned.entries().count == 1)
    }

    // MARK: Favorites

    @Test func favoritesStopAtTwelve() {
        var favorites = BrowserFavorites(profileID: work.id)
        var added: [Bool] = []
        for index in 0..<BrowserFavorites.limit {
            added.append(favorites.add(pin("F\(index)")))
        }
        #expect(added.allSatisfy { $0 })
        #expect(favorites.isFull)
        let before = favorites
        let thirteenth = favorites.add(pin("Thirteenth"))
        #expect(!thirteenth)
        #expect(favorites == before)
        // Decoding or making a list keeps the first twelve.
        let many = BrowserFavorites(profileID: work.id, items: (0..<20).map { pin("P\($0)") })
        #expect(many.items.count == BrowserFavorites.limit)
        #expect(many.items.last?.title == "P11")
    }

    @Test func favoritesAddMoveRemoveAndReplace() throws {
        var favorites = BrowserFavorites(profileID: work.id)
        let a = pin("A")
        let b = pin("B")
        let c = pin("C")
        let added = [favorites.add(a), favorites.add(b), favorites.add(c, at: 0), favorites.add(a)]
        #expect(added == [true, true, true, false])
        #expect(favorites.items.map(\.title) == ["C", "A", "B"])

        favorites.move(c.id, to: 3)
        #expect(favorites.items.map(\.title) == ["A", "B", "C"])
        favorites.move(c.id, to: -4)
        #expect(favorites.items.map(\.title) == ["C", "A", "B"])
        let movedUnknown = favorites.move(UUID(), to: 0)
        #expect(!movedUnknown)

        let replaced = favorites.replace(a.id, url: "https://new.example/", title: "New")
        #expect(replaced)
        #expect(favorites.item(id: a.id)?.url == "https://new.example/")
        #expect(favorites.items.map(\.title) == ["C", "New", "B"])

        let removed = favorites.remove(c.id)
        let removedAgain = favorites.remove(c.id)
        #expect(removed?.title == "C")
        #expect(removedAgain == nil)
        #expect(favorites.items.map(\.title) == ["New", "B"])
    }

    // MARK: File

    @Test func decodingIsTolerant() throws {
        let good = UUID()
        let repeated = UUID()
        let profile = UUID()
        let text = """
        { "version": 1, "spaces": [
          { "id": "\(good.uuidString)", "name": "Work", "icon": { "type": "emoji", "value": "💼" },
            "color": "green", "profileID": "\(profile.uuidString)", "importedFrom": "arc:1",
            "pinned": { "type": "folder", "children": [
              { "type": "pin", "url": "https://a.example/", "title": "A" },
              { "type": "pin", "title": "No address" }
            ] } },
          { "id": "\(repeated.uuidString)", "profileID": "\(profile.uuidString)", "color": "mauve",
            "icon": { "type": "symbol" }, "pinned": "nope" },
          { "id": "\(repeated.uuidString)", "name": "Repeated", "profileID": "\(profile.uuidString)" },
          { "name": "No id", "profileID": "\(profile.uuidString)" },
          { "id": "\(UUID().uuidString)", "name": "No profile" },
          7
        ],
        "favorites": [
          { "profileID": "\(profile.uuidString)", "items": [
            { "type": "pin", "url": "https://fav.example/", "title": "Fav" },
            { "type": "folder", "name": "Not a favorite" },
            { "title": "No address" }
          ] },
          { "profileID": "\(profile.uuidString)", "items": [] },
          { "items": [] }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode(BrowserSpacesFile.self, from: Data(text.utf8)).list
        #expect(list.spaces.map(\.id) == [good, repeated])
        let first = list.spaces[0]
        #expect(first.name == "Work")
        #expect(first.icon == .emoji("💼"))
        #expect(first.color == .green)
        #expect(first.importedFrom == "arc:1")
        #expect(first.pinned.entries().map(\.pin.title) == ["A"])
        let second = list.spaces[1]
        #expect(second.name == "Space")
        #expect(second.color == .blue)
        #expect(second.icon == .none)
        #expect(second.pinned.isEmpty)
        #expect(list.favorites.count == 1)
        #expect(list.favorites(ofProfile: profile).items.map(\.title) == ["Fav"])

        let empty = try decoder.decode(BrowserSpacesFile.self, from: Data(#"{"spaces": "nope"}"#.utf8))
        #expect(empty.list.spaces.isEmpty)
    }

    @Test func listsRoundTripThroughTheFile() throws {
        var list = BrowserSpaceList()
        let created = list.create(
            name: "Work",
            icon: .symbol("briefcase"),
            color: .yellow,
            profileID: work.id,
            pinned: BrowserPinTree(children: [
                .folder(BrowserPinFolder(name: "Docs", addedAt: Date(timeIntervalSince1970: 1_700_000_000), children: [
                    .pin(BrowserPin(url: "https://a.example/", title: "A", addedAt: Date(timeIntervalSince1970: 1_700_000_100))),
                ])),
            ]),
            importedFrom: "arc:space"
        )
        let space = try #require(created)
        let favorite = BrowserPin(url: "https://f.example/", title: "F", addedAt: Date(timeIntervalSince1970: 1_700_000_200))
        list.updateFavorites(ofProfile: work.id) { $0.add(favorite) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(BrowserSpacesFile(list: list))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["version"] as? Int == BrowserSpacesFile.currentVersion)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BrowserSpacesFile.self, from: data).list
        #expect(decoded == list)
        #expect(decoded.space(id: space.id)?.icon == .symbol("briefcase"))
    }
}
