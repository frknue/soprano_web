@testable import SopranoWeb
import AppKit
import Testing

/// Per-site zoom and Keep This Site Awake live with a profile's site
/// decisions: per host, per profile, in memory only in a private window.
@MainActor
struct BrowserSiteZoomStoreTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-web-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func zoomIsRememberedPerHostAndSurvivesARestart() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        let store = BrowserSitePermissionStore(url: url)
        store.set(.camera, .allow, host: "docs.example.com")
        store.setZoom(1.25, host: "Docs.Example.com")
        #expect(store.zoom(host: "docs.example.com") == 1.25)
        #expect(store.zoom(host: "example.com") == nil)

        let relaunched = BrowserSitePermissionStore(url: url)
        #expect(relaunched.zoom(host: "docs.example.com") == 1.25)
        #expect(relaunched.decision(.camera, host: "docs.example.com") == .allow)

        // ⌘0 forgets the zoom and keeps the site's other decisions.
        relaunched.setZoom(nil, host: "docs.example.com")
        #expect(BrowserSitePermissionStore(url: url).sites == ["docs.example.com": ["camera": "allow"]])
    }

    @Test func aZoomThatIsNotALevelIsIgnored() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        try Data("""
        { "version": 1, "sites": {
          "a.example": { "zoom": "12" },
          "b.example": { "zoom": "huge" },
          "c.example": { "zoom": "0.75" }
        } }
        """.utf8).write(to: url)
        let store = BrowserSitePermissionStore(url: url)
        #expect(store.zoom(host: "a.example") == nil)
        #expect(store.zoom(host: "b.example") == nil)
        #expect(store.zoom(host: "c.example") == 0.75)
        store.setZoom(.nan, host: "c.example")
        #expect(store.zoom(host: "c.example") == nil)
    }

    @Test func eachProfileHasItsOwnZoom() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        let work = BrowserProfile(id: UUID(), name: "Work", color: .blue)
        let defaultStore = BrowserSitePermissionStore(url: support.appendingPathComponent("site-permissions.json"))
        let workStore = BrowserSitePermissionStore(
            url: work.directory(in: support).appendingPathComponent("site-permissions.json")
        )
        workStore.setZoom(1.5, host: "example.com")
        #expect(workStore.zoom(host: "example.com") == 1.5)
        #expect(defaultStore.zoom(host: "example.com") == nil)
        defaultStore.setZoom(0.85, host: "example.com")
        #expect(workStore.zoom(host: "example.com") == 1.5)
    }

    @Test func aPrivateWindowReadsSavedZoomAndKeepsItsOwnInMemory() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BrowserSitePermissionStore(url: directory.appendingPathComponent("site-permissions.json"))
        saved.setZoom(1.25, host: "news.example")
        let fileBefore = try Data(contentsOf: try #require(saved.url))

        let overlay = BrowserSitePermissionStore(overlaying: saved)
        #expect(overlay.zoom(host: "news.example") == 1.25)
        overlay.setZoom(2, host: "news.example")
        overlay.setZoom(1.5, host: "shop.example")
        #expect(overlay.zoom(host: "news.example") == 2)
        #expect(overlay.zoom(host: "shop.example") == 1.5)
        #expect(saved.zoom(host: "news.example") == 1.25)
        #expect(saved.zoom(host: "shop.example") == nil)
        #expect(try Data(contentsOf: try #require(saved.url)) == fileBefore)

        // ⌘0 in the private window resets it there, over the saved zoom,
        // without touching the saved one.
        overlay.setZoom(nil, host: "news.example")
        #expect(overlay.zoom(host: "news.example") == nil)
        #expect(saved.zoom(host: "news.example") == 1.25)
        #expect(try Data(contentsOf: try #require(saved.url)) == fileBefore)
    }

    @Test func keepThisSiteAwakeIsAPerHostDecision() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("site-permissions.json")
        let store = BrowserSitePermissionStore(url: url)
        store.setKeepsAwake(true, host: "music.example")
        #expect(store.keepsAwake(host: "music.example"))
        #expect(!store.keepsAwake(host: "example.com"))
        #expect(BrowserSitePermissionStore(url: url).keepsAwake(host: "music.example"))

        let overlay = BrowserSitePermissionStore(overlaying: store)
        overlay.setKeepsAwake(false, host: "music.example")
        #expect(!overlay.keepsAwake(host: "music.example"))
        #expect(store.keepsAwake(host: "music.example"))

        store.setKeepsAwake(false, host: "music.example")
        #expect(BrowserSitePermissionStore(url: url).sites.isEmpty)
    }

    @Test func websitesListsZoomAndKeepAwakeWithTheOtherDecisions() {
        let rows = BrowserWebsiteRow.rows(from: [
            "music.example": ["keepAwake": "allow", "camera": "deny"],
            "docs.example.com": ["zoom": "1.25"],
            "forgot.example": ["zoom": BrowserSitePermissionStore.forgotten],
        ])
        #expect(rows.map(\.host) == ["docs.example.com", "music.example"])
        #expect(rows[0].summary == "Zoom: 125%")
        #expect(rows[1].summary == "Camera: Block · Keep awake: On")
    }
}
