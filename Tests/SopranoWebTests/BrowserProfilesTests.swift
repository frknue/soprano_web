@testable import SopranoWeb
import AppKit
import Testing

/// Profiles: `profiles.json`, where each profile's data lives, and what a
/// window's chrome says about its profile.
@MainActor
struct BrowserProfilesTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-profiles-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    @Test func aMissingFileIsJustTheDefaultProfile() {
        let store = BrowserProfileStore(url: temporaryFile())
        #expect(store.profiles == [.defaultProfile])
        #expect(!store.hasSeveral)
        #expect(store.profiles.first?.isDefault == true)
    }

    @Test func profilesRoundTripThroughTheFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BrowserProfileStore(url: url)
        let work = store.add(name: "Work", color: .green)
        let side = store.add(name: "Side Project")
        store.rename(id: BrowserProfile.defaultID, to: "Personal")
        store.setColor(id: side.id, .red)

        let reloaded = BrowserProfileStore(url: url)
        #expect(reloaded.profiles.map(\.name) == ["Personal", "Work", "Side Project"])
        #expect(reloaded.profile(id: work.id)?.color == .green)
        #expect(reloaded.profile(id: side.id)?.color == .red)
        #expect(reloaded.profiles.first?.id == BrowserProfile.defaultID)
        #expect(reloaded.hasSeveral)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == BrowserProfileList.currentVersion)
        #expect((json?["profiles"] as? [[String: Any]])?.count == 3)
    }

    @Test func decodingIsTolerant() throws {
        let work = UUID()
        let text = """
        {"version": 7, "profiles": [
          {"id": "\(work.uuidString)", "name": "  Work  ", "color": "green", "extra": true},
          {"name": "No id"},
          {"id": "\(work.uuidString)", "name": "Duplicate"},
          {"id": "\(UUID().uuidString)", "color": "ultraviolet"},
          42
        ]}
        """
        let list = try JSONDecoder().decode(BrowserProfileList.self, from: Data(text.utf8))
        // Default is added first; the entry without an id and the repeated
        // id are skipped; a missing name and unknown color get defaults.
        #expect(list.profiles.map(\.name) == ["Default", "Work", "Profile"])
        #expect(list.profiles[1].id == work)
        #expect(list.profiles[1].color == .green)
        #expect(list.profiles[2].color == .blue)

        let movedDefault = """
        {"profiles": [{"id": "\(work.uuidString)", "name": "Work"},
                      {"id": "\(BrowserProfile.defaultID.uuidString)", "name": "Personal", "color": "cyan"}]}
        """
        let reordered = try JSONDecoder().decode(BrowserProfileList.self, from: Data(movedDefault.utf8))
        #expect(reordered.profiles.map(\.name) == ["Personal", "Work"])
        #expect(reordered.profiles[0].color == .cyan)

        let garbage = try JSONDecoder().decode(BrowserProfileList.self, from: Data(#"{"profiles": "nope"}"#.utf8))
        #expect(garbage.profiles == [.defaultProfile])
    }

    @Test func unreadableFileStartsWithDefault() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(BrowserProfileStore(url: url).profiles == [.defaultProfile])
    }

    @Test func namesStayUniqueAndColorsSpread() {
        var list = BrowserProfileList()
        let work = list.add(name: "Work")
        let second = list.add(name: "work")
        let blank = list.add(name: "   ")
        #expect(work.name == "Work")
        #expect(second.name == "work 2")
        #expect(blank.name == "Profile")
        // Default is blue; new profiles take the colors nobody uses yet.
        #expect(work.color == .cyan)
        #expect(second.color == .green)
        list.rename(id: second.id, to: "WORK")
        #expect(list.profile(id: second.id)?.name == "WORK 2")
        list.rename(id: second.id, to: "  ")
        #expect(list.profile(id: second.id)?.name == "WORK 2")
        #expect(list.profile(named: " work ")?.id == work.id)
    }

    @Test func defaultCanBeRenamedButNotRemoved() {
        var list = BrowserProfileList()
        list.rename(id: BrowserProfile.defaultID, to: "Personal")
        list.remove(id: BrowserProfile.defaultID)
        #expect(list.profiles.map(\.name) == ["Personal"])
        let work = list.add(name: "Work")
        list.remove(id: work.id)
        #expect(list.profile(id: work.id) == nil)
        // A window or closed tab of the removed profile opens in Default.
        #expect(list.resolvedID(work.id) == BrowserProfile.defaultID)
        #expect(list.resolvedID(BrowserProfile.defaultID) == BrowserProfile.defaultID)
    }

    @Test func eachProfileHasItsOwnFolderAndDataStore() {
        let support = URL(fileURLWithPath: "/tmp/Soprano Web", isDirectory: true)
        let defaultProfile = BrowserProfile.defaultProfile
        // Default keeps today's files and the default data store.
        #expect(defaultProfile.directory(in: support) == support)
        #expect(defaultProfile.dataStoreIdentifier == nil)

        let id = UUID()
        let work = BrowserProfile(id: id, name: "Work", color: .green)
        #expect(work.directory(in: support).path == "/tmp/Soprano Web/Profiles/\(id.uuidString)")
        #expect(work.dataStoreIdentifier == id)
        let other = BrowserProfile(name: "Other", color: .red)
        #expect(other.directory(in: support) != work.directory(in: support))
    }

    @Test func historyAndSiteDecisionsLiveInTheProfileFolder() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-profile-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let work = BrowserProfile(name: "Work", color: .green)
        let defaultHistory = BrowserHistoryStore(directory: BrowserProfile.defaultProfile.directory(in: support))
        let workHistory = BrowserHistoryStore(directory: work.directory(in: support))
        workHistory.record(url: "https://work.example/", title: "Work")
        #expect(workHistory.visitCount() == 1)
        #expect(defaultHistory.visitCount() == 0)
        #expect(workHistory.databaseURL.deletingLastPathComponent().lastPathComponent == work.id.uuidString)
        #expect(defaultHistory.databaseURL.deletingLastPathComponent().standardizedFileURL == support.standardizedFileURL)
    }

    @Test func windowMarkNamesPrivateAndProfile() {
        let work = BrowserProfile(name: "Work", color: .green)
        #expect(BrowserWindowMark(kind: .normal, profile: nil).text == nil)
        #expect(BrowserWindowMark(kind: .private, profile: nil).text == "Private")
        #expect(BrowserWindowMark(kind: .normal, profile: work).text == "Work")
        let both = BrowserWindowMark(kind: .private, profile: work)
        #expect(both.text == "Private · Work")
        #expect(both.profileColor == .green)
    }

    @Test func deleteConfirmationSaysWhatGoes() {
        let none = BrowserProfilesSheet.deleteConfirmation(name: "Work", windowCount: 0)
        #expect(none.title == "Delete the profile “Work”?")
        #expect(!none.message.contains("window"))
        #expect(BrowserProfilesSheet.deleteConfirmation(name: "Work", windowCount: 1).message.hasPrefix("Its open window closes."))
        #expect(BrowserProfilesSheet.deleteConfirmation(name: "Work", windowCount: 3).message.hasPrefix("Its 3 open windows close."))
    }

    @Test func clearBrowsingDataNamesTheProfile() {
        #expect(BrowserClearBrowsingDataSheet.title(profileName: nil) == "Clear Browsing Data")
        #expect(BrowserClearBrowsingDataSheet.title(profileName: "Work") == "Clear Browsing Data of “Work”")
        #expect(!BrowserClearBrowsingDataSheet.message(profileName: nil).contains("profile"))
        #expect(BrowserClearBrowsingDataSheet.message(profileName: "Work").contains("the Work profile"))
    }
}
