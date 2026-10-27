@testable import SopranoWeb
import AppKit
import Testing

@MainActor
struct BrowserSpaceStoreTests {
    private let work = BrowserProfile(name: "Work", color: .green)

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebSpaces-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func object(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func makeStore(in directory: URL, profiles: [BrowserProfile]? = nil) -> BrowserSpaceStore {
        BrowserSpaceStore(
            url: directory.appendingPathComponent("spaces.json"),
            profiles: profiles ?? [.defaultProfile, work]
        )
    }

    private func defaultSpace(_ store: BrowserSpaceStore) throws -> UUID {
        try #require(store.space(ofProfile: BrowserProfile.defaultID)).id
    }

    // MARK: Migration

    @Test func withoutFilesEveryProfileGetsASpaceNamedAfterIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)

        #expect(store.spaces.map(\.name) == ["Default", "Work"])
        #expect(store.spaces.map(\.color) == [.blue, .green])
        #expect(store.spaces.map(\.profileID) == [BrowserProfile.defaultID, work.id])
        #expect(store.spaces.allSatisfy { $0.icon == .none && $0.pinned.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: store.migratedBookmarksURL.path))
        // Written at once, so the ids are stable from the first launch.
        let file = try object(at: store.url)
        #expect(file["version"] as? Int == 1)
        let reopened = makeStore(in: directory)
        #expect(reopened.spaces == store.spaces)
    }

    @Test func version1BookmarksBecomeDefaultsPinsAndTheFileIsKept() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarksURL = directory.appendingPathComponent("bookmarks.json")
        let old = UUID()
        let new = UUID()
        let original = """
        { "version": 1, "entries": [
          { "id": "\(old.uuidString)", "url": "https://old.example/", "title": "Old", "addedAt": "2023-01-01T00:00:00Z" },
          { "id": "\(new.uuidString)", "url": "https://new.example/", "title": "New", "addedAt": "2024-01-01T00:00:00Z" }
        ] }
        """
        try Data(original.utf8).write(to: bookmarksURL)

        let store = makeStore(in: directory)
        let home = try defaultSpace(store)
        let workSpace = try #require(store.space(ofProfile: work.id)).id
        #expect(store.pinTree(inSpace: home).root.children.map(\.id) == [new, old])
        #expect(store.pinTree(inSpace: workSpace).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bookmarksURL.path))
        #expect(try String(contentsOf: store.migratedBookmarksURL, encoding: .utf8) == original)

        // Once: reopening reads spaces.json and leaves the kept file alone.
        store.addPinFolder(name: "Work", inSpace: home)
        let reopened = makeStore(in: directory)
        #expect(reopened.pinTree(inSpace: home).root.children.map(\.title) == ["New", "Old", "Work"])
        #expect(try String(contentsOf: reopened.migratedBookmarksURL, encoding: .utf8) == original)
    }

    @Test func version2BookmarksMigrateWithTheirFolders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarksURL = directory.appendingPathComponent("bookmarks.json")
        let folder = UUID()
        let original = """
        { "version": 2, "root": { "type": "folder", "children": [
          { "type": "folder", "id": "\(folder.uuidString)", "name": "Docs", "children": [
            { "type": "bookmark", "url": "https://webkit.org/", "title": "WebKit" }
          ] },
          { "type": "bookmark", "url": "https://swift.org/", "title": "Swift" }
        ] } }
        """
        try Data(original.utf8).write(to: bookmarksURL)
        // Stage 2's copy of its own version 1 migration.
        try Data("[]".utf8).write(to: bookmarksURL.appendingPathExtension("migrated"))

        let store = makeStore(in: directory, profiles: [.defaultProfile])
        let home = try defaultSpace(store)
        #expect(store.pinEntries(inSpace: home).map(\.pathText) == ["Docs", "Bookmarks"])
        #expect(store.pinTree(inSpace: home).folder(id: folder)?.name == "Docs")
        #expect(try String(contentsOf: store.migratedBookmarksURL, encoding: .utf8) == original)
        let file = try object(at: store.url)
        let pinned = (file["spaces"] as? [[String: Any]])?.first?["pinned"] as? [String: Any]
        let types = (pinned?["children"] as? [[String: Any]])?.map { $0["type"] as? String }
        #expect(types == ["folder", "pin"])
    }

    @Test func aDamagedFileIsKeptAndEveryProfileStillHasASpace() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("spaces.json")
        try Data("{ not json".utf8).write(to: url)

        let store = makeStore(in: directory)
        #expect(try String(contentsOf: store.corruptURL, encoding: .utf8) == "{ not json")
        #expect(store.spaces.map(\.profileID) == [BrowserProfile.defaultID, work.id])
        #expect(try object(at: url)["version"] as? Int == 1)
    }

    @Test func spacesSharingAProfileAreSeparatedOnLoadOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("spaces.json")
        // Stage 3's file: Work and Side share the Work profile, Home and
        // Reading share Default; Work has favorites.
        let home = BrowserSpace(name: "Home", color: .blue, profileID: BrowserProfile.defaultID)
        let reading = BrowserSpace(name: "Reading", color: .yellow, profileID: BrowserProfile.defaultID)
        let workSpace = BrowserSpace(name: "Work", color: .green, profileID: work.id)
        let side = BrowserSpace(name: "Side", icon: .emoji("🌱"), color: .red, profileID: work.id)
        var favorites = BrowserFavorites(profileID: work.id)
        favorites.add(BrowserPin(url: "https://mail.example/", title: "Mail"))
        let stage3 = BrowserSpaceList(spaces: [home, workSpace, reading, side], favorites: [favorites])
        try JSONFile.write(BrowserSpacesFile(list: stage3), to: url)
        let slowWork = BrowserProfile(id: work.id, name: "Work", color: .green, archiveAfter: .days7)

        let store = makeStore(in: directory, profiles: [.defaultProfile, slowWork])
        #expect(store.separations == [
            BrowserSpaceList.Separation(spaceID: reading.id, from: BrowserProfile.defaultID),
            BrowserSpaceList.Separation(spaceID: side.id, from: work.id),
        ])
        // Each separated Space has a new profile with its own id, name and
        // color, archiving as the shared profile did.
        #expect(store.separatedProfiles.map(\.id) == [reading.id, side.id])
        #expect(store.separatedProfiles.map(\.name) == ["Reading", "Side"])
        #expect(store.separatedProfiles.map(\.archiveAfter) == [.hours12, .days7])
        #expect(store.spaces.map(\.profileID) == [BrowserProfile.defaultID, work.id, reading.id, side.id])
        // Favorites stay with the first Space's profile.
        #expect(store.favorites(ofProfile: work.id).map(\.title) == ["Mail"])
        #expect(store.favorites(ofProfile: side.id).isEmpty)

        // Written once: a second launch (with the new profiles saved)
        // changes nothing.
        let written = try Data(contentsOf: url)
        let again = makeStore(in: directory, profiles: [.defaultProfile, slowWork] + store.separatedProfiles)
        #expect(again.separations.isEmpty)
        #expect(again.spaces == store.spaces)
        #expect(try Data(contentsOf: url) == written)

        // A launch that saved `spaces.json` but not the new profiles keeps
        // the separated Spaces and asks for their profiles again.
        let interrupted = makeStore(in: directory, profiles: [.defaultProfile, slowWork])
        #expect(interrupted.spaces.count == 4)
        #expect(interrupted.separatedProfiles.map(\.id) == [reading.id, side.id])
    }

    // MARK: Spaces

    @Test func everySpaceHasItsOwnProfile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        let store = makeStore(in: directory, profiles: profiles.profiles)
        let side = try #require(store.createSpace(name: "Side", icon: .emoji("🌱"), color: .cyan, profiles: profiles))
        // The Space's profile has its id, its name and color.
        #expect(side.profileID == side.id)
        let profile = try #require(profiles.profile(id: side.id))
        #expect(profile.name == "Side")
        #expect(profile.color == .cyan)
        #expect(store.space(ofProfile: side.id) == side)
        #expect(Set(store.spaces.map(\.profileID)).count == store.spaces.count)

        // Deleting its profile's Space takes it; a profile without a Space
        // gets one again.
        store.deleteSpace(ofProfile: side.id)
        #expect(store.space(id: side.id) == nil)
        let ensured = store.ensureSpace(forProfile: work)
        #expect(ensured.name == "Work")
        #expect(store.ensureSpace(forProfile: work) == ensured)
        #expect(makeStore(in: directory).space(ofProfile: work.id) == ensured)
    }

    @Test func reconcileFollowsTheProfileList() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, profiles: [.defaultProfile])
        var notified = 0
        let observation = store.changes.observe { notified += 1 }
        defer { observation.cancel() }

        store.reconcile(with: [.defaultProfile, work])
        #expect(store.spaces.map(\.name) == ["Default", "Work"])
        store.reconcile(with: [.defaultProfile, work])
        #expect(notified == 1)
        // Opening with a list that lost a profile drops its Space.
        let reopened = makeStore(in: directory, profiles: [.defaultProfile])
        #expect(reopened.spaces.map(\.name) == ["Default"])
    }

    @Test func spaceEditsPersist() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let home = try defaultSpace(store)
        let workSpace = try #require(store.space(ofProfile: work.id))
        store.renameSpace(home, to: "Home")
        store.setSpaceIcon(home, .symbol("house"))
        store.setSpaceColor(home, .red)
        store.moveSpace(workSpace.id, to: 0)

        let reopened = makeStore(in: directory)
        #expect(reopened.spaces.map(\.name) == ["Work", "Home"])
        let saved = try #require(reopened.space(id: home))
        #expect(saved.icon == .symbol("house"))
        #expect(saved.color == .red)
    }

    // MARK: Pins

    @Test func pinsAndFoldersPersistPerSpace() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let home = try defaultSpace(store)
        let workSpace = try #require(store.space(ofProfile: work.id)).id

        let example = try #require(store.addPin(url: "https://example.com", title: "Example", inSpace: home))
        #expect(store.isPinned("https://example.com", inSpace: home))
        #expect(!store.isPinned("https://example.com", inSpace: workSpace))
        store.removePin(example.id, inSpace: home)
        #expect(store.pins(inSpace: home).isEmpty)

        let folder = try #require(store.addPinFolder(name: "Work", inSpace: workSpace))
        store.addPin(url: "https://example.com", title: "Example", to: folder.id, inSpace: workSpace)
        #expect(store.addPin(url: "https://x.example", title: "X", inSpace: UUID()) == nil)
        let reloaded = makeStore(in: directory)
        #expect(reloaded.pins(inSpace: workSpace).map(\.title) == ["Example"])
        #expect(reloaded.pinEntries(inSpace: workSpace).first?.path == ["Work"])
        #expect(reloaded.pins(inSpace: home).isEmpty)
    }

    @Test func pinSearchMatchesTitlesAddressesAndFolderNames() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let home = try defaultSpace(store)
        let work = try #require(store.addPinFolder(name: "Work", inSpace: home))
        let docs = try #require(store.addPinFolder(name: "Docs", in: work.id, inSpace: home))
        store.addPin(url: "https://developer.apple.com/documentation/webkit", title: "WebKit", to: docs.id, inSpace: home)
        store.addPin(url: "https://example.com", title: "Example", inSpace: home)

        #expect(store.matchingPins("webkit", inSpace: home).map(\.pathText) == ["Work › Docs"])
        #expect(store.matchingPins("example.com", inSpace: home).map(\.pathText) == ["Bookmarks"])
        #expect(store.matchingPins("work", inSpace: home).map(\.pin.title) == ["WebKit"])
        #expect(store.matchingPins(" ", inSpace: home).count == 2)
    }

    @Test func importersInsertWholeFolders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let home = try defaultSpace(store)
        let folder = BrowserPinFolder(name: "Imported", children: [
            .pin(BrowserPin(url: "https://a.example/", title: "A")),
        ])
        #expect(store.insert(.folder(folder), inSpace: home))
        #expect(!store.insert(.folder(folder), inSpace: home))
        #expect(!store.insert(.folder(BrowserPinFolder(name: "Lost")), into: UUID(), inSpace: home))
        #expect(store.pinEntries(inSpace: home).map(\.pathText) == ["Imported"])
    }

    // MARK: Favorites

    @Test func favoritesPersistPerProfileUpToTwelve() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        for index in 0..<BrowserFavorites.limit {
            store.addFavorite(url: "https://\(index).example/", title: "\(index)", ofProfile: work.id)
        }
        #expect(store.addFavorite(url: "https://13.example/", title: "13", ofProfile: work.id) == nil)
        #expect(store.favorites(ofProfile: work.id).count == BrowserFavorites.limit)
        #expect(store.favorites(ofProfile: BrowserProfile.defaultID).isEmpty)

        let first = try #require(store.favorites(ofProfile: work.id).first)
        #expect(store.moveFavorite(first.id, to: BrowserFavorites.limit, ofProfile: work.id))
        #expect(store.replaceFavorite(first.id, url: "https://moved.example/", title: "Moved", ofProfile: work.id))
        store.removeFavorite(store.favorites(ofProfile: work.id)[0].id, ofProfile: work.id)

        let reopened = makeStore(in: directory)
        let titles = reopened.favorites(ofProfile: work.id).map(\.title)
        #expect(titles.count == BrowserFavorites.limit - 1)
        #expect(titles.last == "Moved")
        #expect(titles.first == "2")

        // Deleting the profile's Space takes its favorites.
        reopened.deleteSpace(ofProfile: work.id)
        #expect(reopened.favorites(ofProfile: work.id).isEmpty)
    }

    // MARK: UI state

    @Test func pinUIStateRemembersExpandedFoldersAndTheLastFolderPerSpace() {
        let suite = "SopranoWebTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID()
        let docs = UUID()
        let home = UUID()
        let side = UUID()
        let state = BrowserPinUIState(defaults: defaults)
        state.setExpanded(true, folder: work)
        state.setExpanded(true, folder: docs)
        state.setExpanded(false, folder: docs)
        state.setLastFolderID(docs, inSpace: home)
        state.setLastFolderID(work, inSpace: side)

        let reopened = BrowserPinUIState(defaults: defaults)
        #expect(reopened.expandedFolders == [work])
        #expect(reopened.lastFolderID(inSpace: home) == docs)
        #expect(reopened.lastFolderID(inSpace: side) == work)
        #expect(reopened.lastFolderID(inSpace: UUID()) == nil)
    }

    @Test func pinUIStateReadsStageTwoKeysUntilItHasItsOwn() {
        let suite = "SopranoWebTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = UUID()
        let other = UUID()
        defaults.set([folder.uuidString], forKey: BrowserPinUIState.legacyExpandedFoldersKey)
        defaults.set(folder.uuidString, forKey: BrowserPinUIState.legacyLastFolderKey)

        let state = BrowserPinUIState(defaults: defaults)
        #expect(state.expandedFolders == [folder])
        #expect(state.lastFolderID(inSpace: UUID()) == folder)
        state.setExpanded(true, folder: other)
        #expect(BrowserPinUIState(defaults: defaults).expandedFolders == [folder, other])
    }
}
