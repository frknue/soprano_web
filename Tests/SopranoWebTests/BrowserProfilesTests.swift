@testable import SopranoWeb
import AppKit
import Testing

/// Profiles, every Space's data container: `profiles.json`, where each
/// Space's data lives, and what a window's chrome says about its Space.
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
        #expect(store.profiles.first?.isDefault == true)
    }

    @Test func profilesRoundTripAndFollowTheirSpaces() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = BrowserProfileStore(url: url)
        let work = BrowserProfile(name: "Work", color: .green)
        #expect(store.add(work))
        #expect(!store.add(BrowserProfile(id: work.id, name: "Again", color: .red)))
        // A profile's name and color follow its Space's.
        store.follow([
            BrowserSpace(name: "Personal", color: .cyan, profileID: BrowserProfile.defaultID),
            BrowserSpace(name: "  Day Job ", color: .red, profileID: work.id),
        ])

        let reloaded = BrowserProfileStore(url: url)
        #expect(reloaded.profiles.map(\.name) == ["Personal", "Day Job"])
        #expect(reloaded.profile(id: work.id)?.color == .red)
        #expect(reloaded.profiles.first?.id == BrowserProfile.defaultID)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == BrowserProfileList.currentVersion)
        #expect((json?["profiles"] as? [[String: Any]])?.count == 2)
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

    @Test func archiveAfterDecodesTolerantlyAndRoundTrips() throws {
        let work = UUID()
        let home = UUID()
        let text = """
        {"version": 1, "profiles": [
          {"id": "\(BrowserProfile.defaultID.uuidString)", "name": "Default"},
          {"id": "\(work.uuidString)", "name": "Work", "archiveAfter": "days7"},
          {"id": "\(home.uuidString)", "name": "Home", "archiveAfter": "fortnight"}
        ]}
        """
        var list = try JSONDecoder().decode(BrowserProfileList.self, from: Data(text.utf8))
        // Missing (a stage 2 file) and unknown values get the default.
        #expect(list.profiles.map(\.archiveAfter) == [.hours12, .days7, .hours12])
        #expect(BrowserArchiveAfter.default == .hours12)
        #expect(BrowserArchiveAfter.never.interval == nil)
        #expect(BrowserArchiveAfter.hour1.interval == 3_600)

        list.setArchiveAfter(id: home, .never)
        let decoded = try JSONDecoder().decode(BrowserProfileList.self, from: JSONEncoder().encode(list))
        #expect(decoded.profiles.map(\.archiveAfter) == [.hours12, .days7, .never])
    }

    @Test func unreadableFileStartsWithDefault() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(BrowserProfileStore(url: url).profiles == [.defaultProfile])
    }

    @Test func defaultCanBeFollowedButNotRemoved() {
        var list = BrowserProfileList()
        let personal = [BrowserSpace(name: "Personal", color: .blue, profileID: BrowserProfile.defaultID)]
        let changed = list.follow(personal)
        let changedAgain = list.follow(personal)
        #expect(changed && !changedAgain)
        list.remove(id: BrowserProfile.defaultID)
        #expect(list.profiles.map(\.name) == ["Personal"])
        let work = BrowserProfile(name: "Work", color: .green)
        list.add(work)
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

    @Test func windowMarkNamesTheSpace() {
        #expect(BrowserWindowMark(kind: .normal, space: nil).text == nil)
        #expect(BrowserWindowMark(kind: .private, space: nil).text == "Private")
        let work = BrowserSpace(name: "Work", color: .green, profileID: UUID())
        let both = BrowserWindowMark(kind: .private, space: work)
        #expect(both.text == "Private · Work")
        #expect(both.color == .green)
        #expect(both.toolTip?.hasPrefix("Space: Work\nPrivate window") == true)
        // A normal window shows its Space: emoji, name and color.
        let space = BrowserSpace(name: "Research", icon: .emoji("🔬"), color: .blue, profileID: UUID())
        let spaceMark = BrowserWindowMark(kind: .normal, space: space)
        #expect(spaceMark.text == "🔬 Research")
        #expect(spaceMark.color == .blue)
        #expect(spaceMark.toolTip == "Space: Research")
        let plain = BrowserSpace(name: "Home", icon: .symbol("house"), color: .yellow, profileID: UUID())
        #expect(BrowserWindowMark(kind: .normal, space: plain).text == "Home")
    }

    @Test func deleteSpaceConfirmationSaysWhatGoes() {
        let none = BrowserWindowController.deleteSpaceConfirmation(name: "Work", tabCount: 0)
        #expect(none.title == "Delete the Space “Work”?")
        #expect(!none.message.contains("tab closes"))
        #expect(none.message.contains("cookies"))
        #expect(none.message.contains("History"))
        #expect(none.message.contains("pinned tabs"))
        #expect(none.message.contains("Archive"))
        let one = BrowserWindowController.deleteSpaceConfirmation(name: "Work", tabCount: 1)
        #expect(one.message.hasPrefix("Its open tab closes."))
        let three = BrowserWindowController.deleteSpaceConfirmation(name: "Work", tabCount: 3)
        #expect(three.message.hasPrefix("Its 3 open tabs close"))
    }

    @Test func clearBrowsingDataNamesTheSpace() {
        #expect(BrowserClearBrowsingDataSheet.title(spaceName: nil) == "Clear Browsing Data")
        #expect(BrowserClearBrowsingDataSheet.title(spaceName: "Work") == "Clear Browsing Data of “Work”")
        #expect(!BrowserClearBrowsingDataSheet.message(spaceName: nil).contains("Space"))
        #expect(BrowserClearBrowsingDataSheet.message(spaceName: "Work").contains("the Work Space"))
    }
}
