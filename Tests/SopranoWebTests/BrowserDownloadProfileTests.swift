@testable import SopranoWeb
import AppKit
import Testing
import WebKit

/// A download row remembers the profile (the Space's data) of the tab that
/// started it; Resume and Retry run in that profile's data context, never
/// the current Space's.
@MainActor
struct BrowserDownloadProfileTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SopranoWebTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func context(_ profileID: UUID, in directory: URL) -> BrowserDataContext {
        let folder = directory.appendingPathComponent(profileID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return BrowserDataContext(
            kind: .normal,
            profileID: profileID,
            websiteDataStore: .nonPersistent(),
            history: BrowserHistoryStore(directory: folder),
            sitePermissions: BrowserSitePermissionStore(url: folder.appendingPathComponent("site-permissions.json")),
            faviconStore: BrowserFaviconStore(directory: folder.appendingPathComponent("Favicons")),
            connectionSecurity: BrowserConnectionSecurity()
        )
    }

    @Test func aRowFromSpaceBResumesInBsContextWhileAIsCurrent() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = context(BrowserProfile.defaultID, in: directory)
        let b = context(UUID(), in: directory)
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let manager = BrowserDownloadManager(
            store: store,
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"))
        )
        manager.profileContext = { id in [a, b].first { $0.profileID == id } }
        let record = store.begin(url: "https://b.example/big.iso", filename: "big.iso", profileID: b.profileID)
        store.cancel(id: record.id, resumeData: Data("resume".utf8))
        let stopped = store.records[0]
        #expect(stopped.profileID == b.profileID)
        #expect(stopped.canResume)

        // The clicked window shows A; the row continues in B.
        let resumed = manager.dataContext(for: stopped, windowContext: a)
        #expect(resumed === b)
        let configuration = BrowserDownloadManager.downloadConfiguration(for: b)
        #expect(configuration.websiteDataStore === b.websiteDataStore)
        #expect(configuration.websiteDataStore !== a.websiteDataStore)
    }

    @Test func aDeletedSpacesRowNeverResumesInDefault() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultContext = context(BrowserProfile.defaultID, in: directory)
        let work = BrowserProfile(name: "Work", color: .blue)
        let workContext = context(work.id, in: directory)
        let profiles = BrowserProfileStore(url: directory.appendingPathComponent("profiles.json"))
        profiles.add(work)
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let manager = BrowserDownloadManager(
            store: store,
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"))
        )
        // The window manager's wiring, with its `context(for:)` (Default for
        // a profile that no longer exists).
        manager.profileContext = { id in
            BrowserWindowManager.existingProfileContext(id, profiles: profiles) { id in
                id == work.id && profiles.profile(id: id) != nil ? workContext : defaultContext
            }
        }
        let record = store.begin(url: "https://work.example/big.iso", filename: "big.iso", profileID: work.id)
        store.cancel(id: record.id, resumeData: Data("resume".utf8))
        let stopped = store.records[0]
        #expect(manager.dataContext(for: stopped, windowContext: defaultContext) === workContext)

        profiles.remove(id: work.id)
        #expect(manager.dataContext(for: stopped, windowContext: defaultContext) == nil)
        // Default's own rows still continue.
        let own = store.begin(url: "https://default.example/a.zip", filename: "a.zip", profileID: BrowserProfile.defaultID)
        #expect(manager.dataContext(for: own, windowContext: workContext) === defaultContext)
    }

    @Test func aPrivateRowContinuesOnlyInItsOwnWindow() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = context(UUID(), in: directory)
        let privateWindow = BrowserDataContext.makePrivate(over: base)
        let otherPrivateWindow = BrowserDataContext.makePrivate(over: base)
        let store = BrowserDownloadStore(url: directory.appendingPathComponent("downloads.json"))
        let manager = BrowserDownloadManager(
            store: store,
            settingsStore: BrowserSettingsStore(url: directory.appendingPathComponent("settings.json"))
        )
        manager.profileContext = { _ in base }
        let record = store.begin(
            url: "https://private.example/a.zip",
            filename: "a.zip",
            profileID: base.profileID,
            privateContextID: privateWindow.downloadContextID
        )

        #expect(manager.dataContext(for: record, windowContext: privateWindow) === privateWindow)
        #expect(manager.dataContext(for: record, windowContext: otherPrivateWindow) == nil)
        #expect(manager.dataContext(for: record, windowContext: base) == nil)
    }

    @Test func rowsKeepTheirProfileAndOlderRowsAreDefaults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("downloads.json")
        let work = UUID()
        let store = BrowserDownloadStore(url: url)
        let record = store.begin(url: "https://work.example/a.zip", filename: "a.zip", profileID: work)
        store.finish(id: record.id, path: "/tmp/a.zip")
        #expect(BrowserDownloadStore(url: url).records.map(\.profileID) == [work])

        // A file saved before rows had a profile.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries[0]["profileID"] != nil)
        entries[0].removeValue(forKey: "profileID")
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let reloaded = BrowserDownloadStore(url: url)
        #expect(reloaded.records.map(\.filename) == ["a.zip"])
        #expect(reloaded.records.map(\.profileID) == [BrowserProfile.defaultID])
    }
}
